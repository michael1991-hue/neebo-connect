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
    var readingSummary: String {
        switch self {
        case .heartRate: return "❤️ Heart rate"
        case .pulseOximeter, .combined, .custom: return "❤️ Heart rate · 🫧 Oxygen"
        case .generic, .unknown: return "Readings shown once the format is recognised"
        }
    }
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
    var skinCelsius: Double? = nil
    var heartRateValue: Double? { exactHeartRate ?? heartRate.map(Double.init) }
    var oxygenValue: Double? { exactOxygen ?? oxygen.map(Double.init) }

    init(id: UUID = UUID(), time: Date, heartRate: Int?, oxygen: Int?, source: String, continuityID: UUID? = nil, exactHeartRate: Double? = nil, exactOxygen: Double? = nil, skinCelsius: Double? = nil) {
        self.id = id
        self.time = time
        self.heartRate = heartRate
        self.oxygen = oxygen
        self.source = source
        self.continuityID = continuityID
        self.exactHeartRate = exactHeartRate
        self.exactOxygen = exactOxygen
        self.skinCelsius = skinCelsius
    }

    enum CodingKeys: String, CodingKey { case id, time, heartRate, oxygen, source, continuityID, exactHeartRate, exactOxygen, skinCelsius }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        time = try values.decode(Date.self, forKey: .time)
        heartRate = try values.decodeIfPresent(Int.self, forKey: .heartRate)
        oxygen = try values.decodeIfPresent(Int.self, forKey: .oxygen)
        source = try values.decode(String.self, forKey: .source)
        continuityID = try values.decodeIfPresent(UUID.self, forKey: .continuityID)
        exactHeartRate = try values.decodeIfPresent(Double.self, forKey: .exactHeartRate)
        exactOxygen = try values.decodeIfPresent(Double.self, forKey: .exactOxygen)
        skinCelsius = try values.decodeIfPresent(Double.self, forKey: .skinCelsius)
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(time, forKey: .time)
        try values.encodeIfPresent(heartRate, forKey: .heartRate)
        try values.encodeIfPresent(oxygen, forKey: .oxygen)
        try values.encode(source, forKey: .source)
        try values.encodeIfPresent(continuityID, forKey: .continuityID)
        try values.encodeIfPresent(exactHeartRate, forKey: .exactHeartRate)
        try values.encodeIfPresent(exactOxygen, forKey: .exactOxygen)
        try values.encodeIfPresent(skinCelsius, forKey: .skinCelsius)
    }
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
        case .receiving: return "Connected · Receiving readings"
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
    static func customFrame(_ data: Data) -> (heartRate: Int?, oxygen: Int?, battery: Int?, skinCelsius: Double?) {
        // Only the complete nine-byte frame observed in captures is understood.
        // The last two bytes are a little-endian skin temperature in tenths of a degree.
        // A lone percentage in byte 7 is battery only when the last byte is zero.
        let bytes = Array(data)
        guard bytes.count == 9, bytes[0...2].allSatisfy({ $0 == 0 }) else { return (nil, nil, nil, nil) }
        let hr = bytes[4] == 0 && (30...240).contains(Int(bytes[3])) ? Int(bytes[3]) : nil
        let oxygen = bytes[6] == 0 && (70...100).contains(Int(bytes[5])) ? OxygenReading.clamp(Int(bytes[5])) : nil
        let rawTail = Int(bytes[7]) | (Int(bytes[8]) << 8)
        let skin = (280...420).contains(rawTail) ? Double(rawTail) / 10 : nil
        let battery = skin == nil && bytes[8] == 0 && (1...100).contains(Int(bytes[7])) ? Int(bytes[7]) : nil
        return (hr, oxygen, battery, skin)
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
    private var connectionGap: DispatchWorkItem?
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
        let timer = Timer(timeInterval: MeasurementTransportPolicy.interval, repeats: true) { [weak self] _ in
            // This timer runs only while iOS grants execution. BLE events wake us;
            // never use audio, a busy loop or chained reads to prevent suspension.
            self?.requestCustomFallback()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }
    private func requestCustomFallback() {
        if let started = transportPolicy.lastAttempt, pendingRead != nil, Date().timeIntervalSince(started) > 3 {
            pendingRead = nil
            readNext()
        }
        if measurementNotificationsEnabled, let last = lastCustomMeasurement, Date().timeIntervalSince(last) < 4 {
            return
        }
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
    var connectedMonitorName: String {
        if let p = peripheral {
            if let stored = deviceNames[p.identifier]?.trimmingCharacters(in: .whitespacesAndNewlines), !stored.isEmpty { return stored }
            if let name = p.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        }
        if let id = session.deviceID, let stored = deviceNames[id]?.trimmingCharacters(in: .whitespacesAndNewlines), !stored.isEmpty {
            return stored
        }
        return session.enabled ? "Saved monitor" : "No monitor connected"
    }
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
    @Published private(set) var skinCelsius: Double?
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
    private var batteryFromStandard = false
    @Published private(set) var batteryWarning: WearableBatteryPolicy.Level = .ok
    var criticalAlertActive: Bool { alarmActive || staleHeartRateDetected || shareAlertActive }
    @Published private(set) var shareAlertActive = false
    private var shareAlertSensor = false
    @Published private(set) var alarmAcknowledged = false
    @Published var notificationStatus = "Notification permission has not been checked."
    @Published var soundStatus = "Use Test siren to check the iPhone’s current volume."
    @Published var selectedSiren: NivviSiren = NivviSiren(rawValue: UserDefaults.standard.string(forKey: "nivvi.sound.siren") ?? "") ?? .classic {
        didSet { UserDefaults.standard.set(selectedSiren.rawValue, forKey: "nivvi.sound.siren") }
    }
    @Published var selectedRelief: NivviRelief = NivviRelief(rawValue: UserDefaults.standard.string(forKey: "nivvi.sound.relief") ?? "") ?? .soft {
        didSet { UserDefaults.standard.set(selectedRelief.rawValue, forKey: "nivvi.sound.relief") }
    }
    @Published var experimentalCustomAlarms = false { didSet { alarmSettings.experimentalCustomEnabled = experimentalCustomAlarms } }
    @Published var testingSiren = false
    @Published private(set) var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private var alarmEngine = RateAlarmEngine()
    private var siren: AVAudioPlayer?
    private var holdPlayer: AVAudioPlayer?
    private var soundTestTimer: Timer?
    private var retryTimer: Timer?
    private var retrySeconds: TimeInterval = 2
    private var session = SessionIntent()
    private var foreground = UIApplication.shared.applicationState == .active
    @Published var history: [SavedMeasurement] = []
    @Published var liveTrace: [SavedMeasurement] = []
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
        return name.isEmpty ? "They need your attention" : "\(name) needs your attention"
    }
    private var alarmDetail: String {
        guard let kind = alarmKind else { return "A critical heart-rate alert is active." }
        return kind == .low ? "Low heart-rate limit crossed." : "High heart-rate limit crossed."
    }
    func recentAlerts() -> [SavedEvent] {
        var log: [SavedEvent] = []
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        for offset in 0..<7 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            if let rows = try? eventArchive.load(day: day) {
                log.append(contentsOf: rows.filter(Self.isListedAlert))
            }
        }
        return log.sorted { $0.time > $1.time }
    }
    func clearRecentAlerts() {
        do {
            for event in recentAlerts() { try eventArchive.delete(event) }
            events = try eventArchive.load(day: selectedHistoryDay)
            eventDays = try eventArchive.days()
            eventError = nil
        } catch { eventError = "Alerts could not be cleared: \(error.localizedDescription)" }
    }
    private static func isListedAlert(_ event: SavedEvent) -> Bool {
        event.kind == "critical" || event.kind == "alarm" || event.kind == "connection"
            || event.title == "Heart rate back to normal" || event.title == "High heart-rate alert" || event.title == "Low heart-rate alert"
            || event.title == "Check sensor data" || event.title == "Alarm acknowledged"
            || event.title.localizedCaseInsensitiveContains("needs your attention")
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
    private var storedHistoryIDs = Set<UUID>()
    private var freshnessTimer: Timer?
    private lazy var archive = DailyHistoryStore(folder: folder)
    private var historyURL: URL { folder.appendingPathComponent("measurements.json") }
    private var lastFamilyUploadAt: Date?
    private var lastFamilyUploadKey: String?
    private func publishFamilySnapshot() {
        let now = Date()
        let hrFresh = lastHeartRateUpdate.map { now.timeIntervalSince($0) <= 30 } == true
            || lastCustomMeasurement.map { now.timeIntervalSince($0) <= 8 } == true
        let oxFresh = lastOxygenUpdate.map { now.timeIntervalSince($0) <= 30 } == true
        let hr = hrFresh ? (pulseOximeterRate ?? verifiedHeartRate.map(Double.init) ?? customHeartRateCandidate.map(Double.init)) : nil
        let ox = oxFresh ? OxygenReading.clamp(pulseOximeterOxygen ?? verifiedOxygen.map(Double.init) ?? customOxygenCandidate.map(Double.init) ?? -1) : nil
        let points = history.suffix(120).map { FamilySample(t: $0.time.timeIntervalSince1970, hr: $0.heartRateValue, o2: $0.oxygenValue, sk: $0.skinCelsius) }
        let alarm = alarmKind.map { $0 == .high ? "high" : "low" } ?? (staleHeartRateDetected ? "sensor" : "none")
        let key = "\(alarm)|\(connection.rawValue)"
        if key == lastFamilyUploadKey, let last = lastFamilyUploadAt, now.timeIntervalSince(last) < 5 {
            return
        }
        lastFamilyUploadAt = now
        lastFamilyUploadKey = key
        let snapshot = FamilySnapshot(
            captured: now.timeIntervalSince1970,
            heart_rate: hr,
            oxygen: ox,
            source: profile.rawValue,
            alarm: alarm,
            connection: connection.rawValue,
            history: Array(points),
            heart_rate_at: hr == nil ? nil : (lastHeartRateUpdate ?? lastCustomMeasurement)?.timeIntervalSince1970,
            oxygen_at: ox == nil ? nil : lastOxygenUpdate?.timeIntervalSince1970,
            acknowledged: alarmAcknowledged,
            activity_secret: LiveActivityPush.secret,
            place: UserDefaults.standard.string(forKey: "nivvi.place"),
            host_relation: FamilyRelation.wire(UserDefaults.standard.string(forKey: "nivvi.host.relation")),
            battery: battery,
            charging: wearableCharging,
            skin: skinCelsius,
            alerts: heartAlertsToShare()
        )
        Task { @MainActor in FamilyRelay.shared.capture(snapshot) }
        pushLocalShare()
    }
    private func pushLocalShare() {
        guard WiFiRelay.shared.hosting else { return }
        let hr = pulseOximeterRate ?? verifiedHeartRate.map(Double.init) ?? customHeartRateCandidate.map(Double.init)
        let ox = (pulseOximeterOxygen ?? verifiedOxygen.map(Double.init) ?? customOxygenCandidate.map(Double.init)).flatMap(OxygenReading.clamp)
        WiFiRelay.shared.publish(
            heartRate: hr.map { "\(MetricText.number($0)) bpm" } ?? "No reading",
            oxygen: ox.map { "\(MetricText.number($0))%" } ?? "No reading",
            connection: connection.label,
            alarm: alarmKind.map { $0 == .high ? "high" : "low" } ?? (staleHeartRateDetected ? "sensor" : "none"),
            charging: wearableCharging,
            battery: battery,
            history: Array(history.suffix(120).map { FamilySample(t: $0.time.timeIntervalSince1970, hr: $0.heartRateValue, o2: $0.oxygenValue, sk: $0.skinCelsius) }),
            acknowledged: alarmAcknowledged,
            skin: skinCelsius,
            alerts: heartAlertsToShare()
        )
        let title = UserDefaults.standard.string(forKey: "nivvi.profile.name").flatMap { $0.isEmpty ? nil : $0 } ?? "Nivvi"
        LiveActivityPush.publish(
            title: title,
            heartRate: hr.map { "\(MetricText.number($0)) bpm" } ?? "No reading",
            oxygen: ox.map { "\(MetricText.number($0))%" } ?? "No reading",
            connection: "Shared over Wi‑Fi",
            measuredAt: lastHeartRateUpdate ?? lastCustomMeasurement ?? Date(),
            session: title
        )
    }
    private func saveMeasurement(heartRate: Int?, oxygen: Int?, source: String, exactHeartRate: Double? = nil, exactOxygen: Double? = nil, segment: UUID? = nil) {
        let entry = SavedMeasurement(time: Date(), heartRate: heartRate, oxygen: oxygen.flatMap(OxygenReading.clamp), source: source, continuityID: segment ?? continuityID, exactHeartRate: exactHeartRate, exactOxygen: exactOxygen.flatMap(OxygenReading.clamp), skinCelsius: skinCelsius)
        appendLiveTrace(entry)
        // Oxygen-only packets must not refresh the live-heart-rate freshness timer.
        // A pulse-oximeter can legally report oxygen without a usable pulse.
        if heartRate != nil || exactHeartRate != nil { measurementTime = entry.time }
        guard !historyLoadFailed, sampling.shouldStore(source: source, at: entry.time) else { return }
        do {
            try archive.append(entry)
            sampling.didStore(source: source, at: entry.time)
            storedHistoryIDs.insert(entry.id)
            if Calendar.current.isDate(entry.time, inSameDayAs: selectedHistoryDay) { history.append(entry) }
            let today = Calendar.current.startOfDay(for: entry.time)
            if !historyDays.contains(today) { historyDays = try archive.days() }
            historyError = nil
            if !foreground { lastBackgroundSave = entry.time }
        } catch { historyError = "History could not be saved: \(error.localizedDescription)" }
    }
    private var lastLiveTrace: Date?
    private func appendLiveTrace(_ entry: SavedMeasurement) {
        guard entry.heartRateValue != nil || entry.oxygenValue != nil else { return }
        if let last = lastLiveTrace, entry.time.timeIntervalSince(last) < 0.5 { return }
        lastLiveTrace = entry.time
        liveTrace.append(entry)
        let cut = Date().addingTimeInterval(-120)
        if liveTrace.first?.time ?? cut < cut { liveTrace.removeAll { $0.time < cut } }
    }
    func heartAlertsToShare() -> [FamilyAlert] {
        recentAlerts().filter(SharedAlertLog.shares).prefix(40).map {
            FamilyAlert(id: $0.id.uuidString, t: $0.time.timeIntervalSince1970, title: String($0.title.prefix(80)), detail: String($0.detail.prefix(240)), hr: $0.heartRate)
        }
    }
    func ingestSharedAlerts(_ alerts: [FamilyAlert]) {
        guard !alerts.isEmpty else { return }
        for alert in alerts {
            guard let id = UUID(uuidString: alert.id) else { continue }
            let time = Date(timeIntervalSince1970: alert.t)
            let existing = (try? eventArchive.load(day: time)) ?? []
            if existing.contains(where: { $0.id == id }) { continue }
            if existing.contains(where: { $0.title == alert.title && abs($0.time.timeIntervalSince(time)) < 30 }) { continue }
            let event = SavedEvent(id: id, time: time, kind: "critical", title: alert.title, detail: alert.detail, heartRate: alert.hr)
            do {
                try eventArchive.append(event)
                if Calendar.current.isDate(time, inSameDayAs: selectedHistoryDay) { events.append(event) }
                eventDays = try eventArchive.days()
                eventError = nil
            } catch {
                eventError = "Event could not be saved: \(error.localizedDescription)"
            }
        }
    }
    func selectHistoryDay(_ day: Date) {
        let day = Calendar.current.startOfDay(for: day)
        selectedHistoryDay = day
        do { history = try archive.load(day: day); rememberHistoryIDs(history); historyError = nil }
        catch { history = []; historyError = "This day could not be read. Original history is preserved." }
        do { events = try eventArchive.load(day: day); eventError = nil }
        catch { events = []; eventError = "This day's events could not be read. Original log is preserved." }
    }
    func ingestShared(_ entries: [SavedMeasurement]) {
        guard !historyLoadFailed else { return }
        for entry in entries.sorted(by: { $0.time < $1.time }) {
            guard entry.heartRateValue != nil || entry.oxygenValue != nil else { continue }
            let slot = SharedHistoryPolicy.slot(source: entry.source, time: entry.time)
            guard !storedHistoryIDs.contains(entry.id), !storedHistoryIDs.contains(slot) else { continue }
            storedHistoryIDs.insert(entry.id)
            storedHistoryIDs.insert(slot)
            do {
                try archive.append(entry)
                sampling.didStore(source: entry.source, at: entry.time)
                if Calendar.current.isDate(entry.time, inSameDayAs: selectedHistoryDay) {
                    history.append(entry)
                    history.sort { $0.time < $1.time }
                }
                let day = Calendar.current.startOfDay(for: entry.time)
                if !historyDays.contains(day) { historyDays = try archive.days() }
                historyError = nil
            } catch {
                storedHistoryIDs.remove(entry.id)
                storedHistoryIDs.remove(slot)
                historyError = "History could not be saved: \(error.localizedDescription)"
            }
        }
    }
    private func rememberHistoryIDs(_ entries: [SavedMeasurement]) {
        for entry in entries {
            storedHistoryIDs.insert(entry.id)
            storedHistoryIDs.insert(SharedHistoryPolicy.slot(source: entry.source, time: entry.time))
        }
    }
    func clearHistory() {
        do {
            try archive.clear(legacy: historyURL)
            try eventArchive.clear()
            UserDefaults.standard.removeObject(forKey: "nivvi.sleep.timer")
            events = []; eventDays = []; eventError = nil; sampling.reset()
            history = []; historyDays = []; historyError = nil; historyLoadFailed = false
            storedHistoryIDs = []
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
        customHeartRateCandidate = nil; customOxygenCandidate = nil; skinCelsius = nil
        measurementTime = nil; lastCustomMeasurement = nil
        if resetFreshness { lastHeartRateUpdate = nil; lastOxygenUpdate = nil }
        if resetFreshness { heartRateFreshness.reset(); staleHeartRate.reset(); staleHeartRateDetected = false; continuityID = UUID(); plxContinuityID = UUID() }
        alarmEngine.interrupt()
    }
    private func pauseHeartRate(_ reason: String) {
        let recent = lastHeartRateUpdate.map { Date().timeIntervalSince($0) <= 15 } ?? false
        if recent {
            measurementStatus = reason
            return
        }
        if heartRateFreshness.pause() {
            continuityID = UUID(); sampling.reset()
            if !alarmActive && !wearableCharging { notify(title: "Check sensor data", body: "No fresh reading received. Check the wearable and connection.", identifier: "nivvi-sensor-paused", soundName: "NivviSensor.wav") }
        }
        verifiedHeartRate = nil; customHeartRateCandidate = nil; alarmEngine.interrupt()
        pulseOximeterRate = nil
        if connection.isConnected { connection = .waiting }
        status = "No fresh heart-rate reading. Bluetooth may still be connected."
        measurementStatus = reason
        pushLockScreen(stale: true)
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
        cancelConnectionLossNotice()
        connection = .receiving
        status = wearableCharging ? "Charging" : "Receiving fresh heart-rate readings."
        pushLocalShare()
        pushLockScreen(stale: false)
    }
    private func pushLockScreen(stale: Bool = false) {
        let ble = connection.isConnected || connection == .reconnecting || connection == .waiting
        guard ble || stale else { return }
        NivviLiveActivityBridge.preferLocalBluetooth = true
        LiveActivityPush.claimLocal()
        let hr = pulseOximeterRate ?? verifiedHeartRate.map(Double.init) ?? customHeartRateCandidate.map(Double.init)
        let ox = pulseOximeterOxygen ?? verifiedOxygen.map(Double.init) ?? customOxygenCandidate.map(Double.init)
        NivviLiveActivityBridge.sync(
            title: UserDefaults.standard.string(forKey: "nivvi.profile.name").flatMap { $0.isEmpty ? nil : $0 } ?? "Nivvi",
            heartRate: hr.map { "\(MetricText.number($0)) bpm" } ?? "No reading",
            oxygen: ox.map { "\(MetricText.number($0))%" } ?? "No reading",
            connection: connection.label,
            signal: BluetoothSignal.label(signalRSSI),
            nurseryHint: "",
            monitoring: true,
            measuredAt: lastHeartRateUpdate ?? Date(timeIntervalSince1970: 0),
            stale: stale,
            alarm: alarmKind?.rawValue ?? ""
        )
    }
    private func expireMeasurements() {
        defer { publishFamilySnapshot() }
        if let time = oxygenTime, Date().timeIntervalSince(time) > 30 || Date() < time {
            pulseOximeterOxygen = nil; oxygenTime = nil
            plxContinuityID = UUID(); sampling.reset(source: "standard-PLX-oxygen")
            pulseOximeterStatus = "No fresh oxygen reading received for over 30 seconds."
        }
        if heartRateFreshness.isExpired(at: Date()) {
            pauseHeartRate("No usable heart-rate reading received for over \(Int(HeartRateFreshness.timeout)) seconds. Check the wearable and connection; the cause is unknown.")
        }
        if criticalAlertActive, !alarmAcknowledged, !shareAlertSensor, siren?.isPlaying != true, !testingSiren {
            startSiren(loop: true)
        }
        guard let time = measurementTime, Date().timeIntervalSince(time) > HeartRateFreshness.timeout else { return }
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
        NotificationCenter.default.addObserver(self, selector: #selector(audioRouteChanged),
                                               name: AVAudioSession.routeChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(powerStateChanged),
                                               name: .NSProcessInfoPowerStateDidChange, object: nil)
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
            rememberHistoryIDs(history)
        } catch { historyLoadFailed = true; historyError = "Saved history could not be read. Original files preserved; storage is paused." }
        freshnessTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.expireMeasurements() }
    }
    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge, .criticalAlert]) { [weak self] _, _ in self?.refreshNotificationStatus() }
    }
    func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                self?.notificationSoundAllowed = settings.authorizationStatus == .authorized && settings.soundSetting == .enabled
                if settings.authorizationStatus != .authorized || settings.soundSetting != .enabled {
                    self?.notificationStatus = "Notification sound is not fully enabled. Check iPhone Settings → Notifications → Nivvi."
                } else if settings.criticalAlertSetting == .enabled {
                    self?.notificationStatus = "Critical Alerts allowed. A heart-rate alarm can sound when the phone is on Silent or in Focus. Check-sensor notices stay ordinary."
                } else {
                    self?.notificationStatus = "Notifications allowed. Turn on Critical Alerts in iPhone Settings → Notifications → Nivvi so a heart-rate alarm can sound on Silent."
                }
            }
        }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // The foreground alarm already loops its own sound. Tests play the notification sound.
        let alarmNotification = ["nivvi-rate-alarm", "nivvi-rate-alarm-reminder"].contains(notification.request.identifier)
        completionHandler(alarmNotification && foreground ? [.banner] : [.banner, .sound])
    }
    private func notify(title: String, body: String, identifier: String, delay: TimeInterval? = nil, sirenSound: Bool = true, soundName: String? = nil, repeatInterval: TimeInterval? = nil, critical: Bool = false) {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body
        if critical {
            content.interruptionLevel = .critical
            if let soundName {
                content.sound = UNNotificationSound.criticalSoundNamed(UNNotificationSoundName(soundName), withAudioVolume: 1)
            } else {
                content.sound = UNNotificationSound.defaultCritical
            }
        } else if let soundName {
            content.sound = UNNotificationSound(named: UNNotificationSoundName(rawValue: soundName))
            content.interruptionLevel = soundName == "NivviSensor.wav" ? .active : .timeSensitive
        } else {
            content.sound = sirenSound ? UNNotificationSound(named: UNNotificationSoundName(rawValue: selectedSiren.notificationFile)) : .default
            content.interruptionLevel = .timeSensitive
        }
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
    private func scheduleConnectionLossNotice(lastReading: Date?) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["nivvi-connection"])
        let delay = ConnectionLossPolicy.notifyDelay(lastReading: lastReading, now: Date())
        notify(title: "Nivvi connection lost", body: "No live measurements. Reconnecting to the wearable automatically.", identifier: "nivvi-connection", delay: delay, sirenSound: false)
    }
    private func cancelConnectionLossNotice() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["nivvi-connection"])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["nivvi-connection"])
    }
    private func scheduleAlarmNotifications(title: String? = nil, body: String? = nil) {
        let sensorOnly = staleHeartRateDetected && !alarmActive
        let selectedSound = sensorOnly ? "NivviSensor.wav" : selectedSiren.notificationFile
        let selectedTitle = sensorOnly ? "Check sensor data" : (title ?? attentionTitle)
        let alertBody = body ?? "\(alarmDetail) Check \(displayNameForAlert) and follow the care plan."
        notify(title: selectedTitle, body: alertBody, identifier: "nivvi-rate-alarm", soundName: selectedSound, critical: !sensorOnly)
        // iOS does not permit an app to hold an audio session open indefinitely
        // after backgrounding. Repeating time-sensitive reminders keep notifying
        // the caregiver until acknowledgement or a fresh in-range reading.
        if !sensorOnly { notify(title: selectedTitle, body: "This heart-rate alert is still active. Open Nivvi to acknowledge it.", identifier: "nivvi-rate-alarm-reminder", soundName: selectedSound, repeatInterval: 60, critical: true) }
    }
    private func clearAlarmNotifications() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["nivvi-rate-alarm", "nivvi-rate-alarm-reminder"])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["nivvi-rate-alarm", "nivvi-rate-alarm-reminder"])
    }
    private var displayNameForAlert: String {
        let name = UserDefaults.standard.string(forKey: "nivvi.profile.name")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "them" : name
    }
    private func configureAlarmAudio() throws {
        let audio = AVAudioSession.sharedInstance()
        if audio.category != .playback {
            try audio.setCategory(.playback, mode: .default, options: [])
        }
        try audio.setActive(true)
    }
    private func playReliefSound() {
        guard foreground else { return }
        do {
            guard let url = Bundle.main.url(forResource: selectedRelief.resource, withExtension: "wav") else { throw CocoaError(.fileNoSuchFile) }
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
            guard let url = Bundle.main.url(forResource: sensorOnly ? "NivviSensor" : selectedSiren.resource, withExtension: "wav") else { throw CocoaError(.fileNoSuchFile) }
            try configureAlarmAudio()
            siren = try AVAudioPlayer(contentsOf: url); siren?.numberOfLoops = sensorOnly ? 0 : (loop ? -1 : 0); siren?.volume = sensorOnly ? 0.4 : 1
            guard siren?.play() == true else { throw CocoaError(.fileReadUnknown) }
            soundStatus = sensorOnly ? "Gentle sensor-check chime." : "Siren playing as media audio — the Silent switch does not mute this. Turn the volume buttons up. Lock-screen notification pings can still be silent."
        } catch { soundStatus = "Siren could not play: \(error.localizedDescription)" }
    }
    private func stopSiren() {
        soundTestTimer?.invalidate(); soundTestTimer = nil; testingSiren = false
        siren?.stop(); siren = nil
        refreshBackgroundHold()
    }
    func refreshBackgroundHold() {
        let need = session.enabled || WiFiRelay.shared.hosting || WiFiRelay.shared.following || FamilyRelay.keepBackgroundHold
        if !need || testingSiren || (criticalAlertActive && !alarmAcknowledged) {
            holdPlayer?.stop(); holdPlayer = nil
            return
        }
        startMonitoringHold()
    }
    private func startMonitoringHold() {
        if holdPlayer?.isPlaying == true { return }
        do {
            try configureAlarmAudio()
            guard let url = Bundle.main.url(forResource: "NivviHold", withExtension: "wav") else { return }
            holdPlayer = try AVAudioPlayer(contentsOf: url)
            holdPlayer?.numberOfLoops = -1
            holdPlayer?.volume = 0
            _ = holdPlayer?.play()
        } catch {
            holdPlayer = nil
        }
    }
    func beginShareAlert(sensor: Bool) {
        if shareAlertActive && shareAlertSensor == sensor {
            if alarmAcknowledged { stopSiren(); return }
            return
        }
        shareAlertSensor = sensor
        shareAlertActive = true
        if alarmAcknowledged {
            stopSiren()
            return
        }
        alarmAcknowledged = false
        notify(
            title: sensor ? "Check sensor data" : attentionTitle,
            body: sensor ? "The monitoring phone reports no fresh heart-rate data. Check the wearer and the wearable." : "The monitoring phone has a heart-rate alert. Check \(displayNameForAlert) and follow the care plan.",
            identifier: "nivvi-wifi-share-alarm",
            soundName: sensor ? "NivviSensor.wav" : selectedSiren.notificationFile,
            critical: !sensor
        )
        if !sensor {
            notify(
                title: attentionTitle,
                body: "This heart-rate alert is still active. Open Nivvi and tap Heard it.",
                identifier: "nivvi-wifi-share-alarm-reminder",
                soundName: selectedSiren.notificationFile,
                repeatInterval: 60,
                critical: true
            )
        }
        startSiren(loop: !sensor)
    }
    func endShareAlert() {
        guard shareAlertActive else { return }
        shareAlertActive = false
        shareAlertSensor = false
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["nivvi-wifi-share-alarm", "nivvi-wifi-share-alarm-reminder"])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["nivvi-wifi-share-alarm", "nivvi-wifi-share-alarm-reminder"])
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
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge, .criticalAlert]) { [weak self] allowed, _ in
            guard allowed else { self?.refreshNotificationStatus(); return }
            DispatchQueue.main.async {
                self?.notify(title: "Nivvi sound test", body: "TEST ONLY — no device reading triggered this sound.", identifier: "nivvi-sound-test", delay: 10)
                self?.soundStatus = "Test notification scheduled in 10 seconds. Lock the phone now to test it."
            }
        }
    }
    @objc private func audioInterrupted(_ note: Notification) {
        let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
        guard type == AVAudioSession.InterruptionType.ended.rawValue else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        if criticalAlertActive, !alarmAcknowledged {
            startSiren(loop: true)
        } else {
            refreshBackgroundHold()
        }
        WiFiRelay.shared.revive()
    }
    @objc private func audioRouteChanged(_ note: Notification) {
        let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
            || reason == AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue {
            if criticalAlertActive, !alarmAcknowledged { startSiren(loop: true) }
            else { refreshBackgroundHold() }
            WiFiRelay.shared.revive()
        }
    }
    @objc private func powerStateChanged() {
        DispatchQueue.main.async { self.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled }
    }
    private func beginBackgroundWork() {
        endBackgroundWork()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "nivvi.monitor") { [weak self] in
            self?.endBackgroundWork()
        }
    }
    private func endBackgroundWork() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
    @objc private func enteredBackground() { applicationActive(false) }
    @objc private func becameActive() { applicationActive(true) }
    func applicationActive(_ isActive: Bool) {
        guard foreground != isActive else { return }
        foreground = isActive
        if isActive {
            endBackgroundWork()
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
            WiFiRelay.shared.revive()
            refreshBackgroundHold()
        } else {
            beginBackgroundWork()
            backgroundReadingCount = 0
            if session.enabled {
                backgroundEnteredAt = Date()
                recordEvent(kind: "measurement", title: "Background monitoring started",
                            detail: "Recording continues while Nivvi stays in the app switcher. Swiping Nivvi away stops monitoring until you open it again.")
                scheduleBackgroundWatchdog()
            }
            if criticalAlertActive, !alarmAcknowledged, alarmActive {
                notify(title: attentionTitle, body: "A heart-rate alarm is still active. Open Nivvi to acknowledge it.", identifier: "nivvi-rate-alarm", critical: true)
                startSiren(loop: true)
            } else {
                refreshBackgroundHold()
            }
            // Stop only a user-initiated browse. Keep a saved-device recovery scan.
            if isScanning && !session.enabled {
                scanToken = UUID(); scanDeadline?.invalidate(); manager.stopScan(); connection = .idle
            }
            if retryTimer != nil { beginRecoveryScan() }
            requestCustomFallback()
            WiFiRelay.shared.revive()
        }
    }
    private func saveSession() {
        UserDefaults.standard.set(session.enabled, forKey: "nivvi.session.enabled")
        UserDefaults.standard.set(session.deviceID?.uuidString, forKey: "nivvi.session.device")
    }
    private func resetTransport(clearBattery: Bool = false) {
        pollTimer?.invalidate(); pollTimer = nil; noDataTimer?.invalidate()
        retryTimer?.invalidate(); retryTimer = nil; rssiTimer?.invalidate(); rssiTimer = nil
        transportPolicy.reset()
        signalRSSI = nil
        measurementNotificationsEnabled = false
        readQueue = []; pendingRead = nil; measurementCharacteristic = nil
        lastSample = nil
        if clearBattery {
            clearLiveValues()
            battery = "—"
            batteryFromStandard = false
            batteryPolicy.reset()
            batteryWarning = .ok
        }
        chargePolicy.reset()
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
                    self.refreshBackgroundHold()
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
        let logs = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        files = Array(logs.prefix(1))
        for stale in logs.dropFirst(1) { try? FileManager.default.removeItem(at: stale) }
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
        refreshBackgroundHold()
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
        let briefGap = connectionGap != nil
        connectionGap?.cancel()
        connectionGap = nil
        cancelConnectionLossNotice()
        if !briefGap {
            recordEvent(kind: "connection", title: "Wearable connected", detail: "Continuous Bluetooth session active. Awaiting fresh measurements.")
        } else {
            note("Bluetooth returned within 20 seconds. No connection alert was saved.")
        }
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
        let lastReading = lastHeartRateUpdate
        resetTransport(); connection = .reconnecting
        connectionGap?.cancel()
        let gap = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.connectionGap = nil
            self.recordEvent(kind: "connection", title: "Connection lost", detail: "Measurements unavailable. Automatically reconnecting to the wearable.")
            self.scheduleConnectionLossNotice(lastReading: lastReading)
        }
        connectionGap = gap
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: gap)
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
        if !foreground { beginBackgroundWork() }
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
            if let skin = candidate.skinCelsius { skinCelsius = skin }
            if candidate.oxygen != nil { lastOxygenUpdate = Date() }
            if candidate.heartRate != nil { receiveHeartRate(at: Date()) }
            else { pauseHeartRate("No usable heart rate in the mapped Bluetooth packet. Oxygen or other values do not confirm a fresh heart rate.") }
            measurementStatus = candidate.heartRate == nil && candidate.oxygen == nil ? "Bluetooth measurement received (\(data.count) bytes), but the values or frame format are not recognised." : "Mapped Bluetooth values received. Verify readings with your care plan."
            if candidate.heartRate != nil || candidate.oxygen != nil {
                saveMeasurement(heartRate: candidate.heartRate, oxygen: candidate.oxygen, source: "experimental-custom")
                if let candidateRate = candidate.heartRate { evaluateExperimentalRateAlarm(candidateRate) }
                else { alarmEngine.interrupt() }
            } else { measurementTime = nil; alarmEngine.interrupt() }
            if let percent = candidate.battery { applyBatteryPercent(percent, fromStandard: false) }
            if candidate.oxygen != nil { pushLocalShare() }
        }
        if serviceID == "1822", uuid == "2A5E" || uuid == "2A5F" { receivePulseOximetry(data, characteristic: uuid) }
        if let i = readings.firstIndex(where: { $0.id == key }) {
            readings[i].count += 1; readings[i].hex = hex
        } else { readings.append(Reading(id:key, count:1, hex:hex)) }
        if uuid == "2A19", serviceID == "180F", data.count == 1, data[0] <= 100 {
            applyBatteryPercent(Int(data[0]), fromStandard: true)
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
            quietAlarmsForCharging()
            status = "Charging"
            if record {
                recordEvent(kind: "connection", title: "Wearable charging", detail: "The battery rose or the band reported charging. Heart-rate alerts stay quiet until charging ends. Readings are still saved.")
            }
        } else if record {
            recordEvent(kind: "connection", title: "Charging ended", detail: "The band is no longer charging. Heart-rate alerts use the next fresh readings.")
        }
    }
    private func quietAlarmsForCharging() {
        alarmEngine.reset()
        alarmKind = nil
        staleHeartRate.reset()
        staleHeartRateDetected = false
        shareAlertActive = false
        shareAlertSensor = false
        alarmAcknowledged = false
        clearAlarmNotifications()
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["nivvi-wifi-share-alarm", "nivvi-wifi-share-alarm-reminder"])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["nivvi-wifi-share-alarm", "nivvi-wifi-share-alarm-reminder"])
        if !testingSiren { stopSiren() }
        publishFamilySnapshot()
    }
    private func applyBatteryPercent(_ percent: Int, fromStandard: Bool) {
        guard (0...100).contains(percent) else { return }
        if fromStandard { batteryFromStandard = true }
        else if batteryFromStandard { return }
        battery = "\(percent)%"
        chargePolicy.observeLevel(percent)
        applyCharging(chargePolicy.isCharging)
        applyBatteryWarning(percent)
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
            recordEvent(kind: "measurement", title: "Check sensor data", detail: "The wearable repeated \(value) bpm for five minutes of \(source) readings. Check sensor contact and fit; this may be stale device data.", heartRate: Int(bpm.rounded()))
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
        if wearableCharging { return }
        observeStaleHeartRate(pulse, source: "pulse-oximeter")
        let previous = alarmKind
        let event = alarmEngine.ingestExact(bpm: pulse, source: "standard-PLX-continuous", at: Date(), settings: alarmSettings)
        alarmKind = alarmEngine.active
        if let event = event {
            alarmAcknowledged = false
            recordEvent(kind: "critical", title: event.title, detail: "Pulse oximeter reading \(MetricText.number(pulse)) bpm crossed the configured limit for \(alarmSettings.durationSeconds) seconds.", heartRate: Int(pulse.rounded()))
            startSiren(loop: true)
            scheduleAlarmNotifications()
        } else if previous != nil && !alarmActive {
            alarmAcknowledged = false
            recordEvent(kind: "critical", title: "Heart rate back to normal", detail: "Fresh pulse-oximeter reading \(MetricText.number(pulse)) bpm returned within the configured limits.", heartRate: Int(pulse.rounded()))
            clearAlarmNotifications()
            if !testingSiren { stopSiren() }
            playReliefSound()
        }
    }
    private func evaluateExperimentalRateAlarm(_ bpm: Int) {
        if wearableCharging { return }
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
        if wearableCharging { return }
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
            detail = "\(attentionTitle) stale-data warning acknowledged. Check the sensor; it remains visible until fresh data replaces the repeated value."
        }
        recordEvent(kind: alarmActive ? "critical" : "measurement", title: alarmActive ? "Alarm acknowledged" : "Sensor warning acknowledged", detail: detail)
        alarmAcknowledged = true
        stopSiren()
        clearAlarmNotifications()
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["nivvi-wifi-share-alarm", "nivvi-wifi-share-alarm-reminder"])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["nivvi-wifi-share-alarm", "nivvi-wifi-share-alarm-reminder"])
        soundStatus = "Acknowledged. The alarm stays active until a fresh in-range reading."
        publishFamilySnapshot()
    }
    func releaseForHandover(_ notice: String) {
        let holding = connection.isBusy || connection == .scanning || session.enabled
        guard holding else { return }
        handoverNotice = notice
        notify(title: "Nivvi monitoring moved", body: notice, identifier: "nivvi-handover", sirenSound: false)
        stop()
    }
    func stop() {
        let moved = handoverNotice
        if session.enabled { recordEvent(kind: "connection", title: moved == nil ? "Session disconnected" : "Monitoring moved", detail: moved ?? "Disconnected by the user. Automatic reconnection is off.") }
        session.stop(); saveSession(); cancelBackgroundWatchdog(); retryScan = false; backgroundEnteredAt = nil
        scanToken = UUID(); scanDeadline?.invalidate(); manager.stopScan()
        resetTransport(clearBattery: true); closeCaptureLog(); alarmEngine.reset(); alarmKind = nil; staleHeartRate.reset(); staleHeartRateDetected = false; alarmAcknowledged = false; clearAlarmNotifications(); cancelConnectionLossNotice(); stopSiren()
        if let p = peripheral, p.state != .disconnected && manager.state == .poweredOn {
            connection = .stopping; status = "Disconnecting…"; manager.cancelPeripheralConnection(p)
        } else { finish("Disconnected. Automatic reconnection is off.") }
        refreshBackgroundHold()
    }
    private var handoverNotice: String?
    private func finish(_ message: String) {
        let shown = handoverNotice ?? message
        handoverNotice = nil
        resetTransport(clearBattery: true); closeCaptureLog()
        cancelConnectionLossNotice()
        connection = .idle; peripheral = nil; status = shown
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
    private let genders = ["Girl", "Boy", "Woman", "Man", "Other", "Prefer not to say"]
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
                    Text("Photos cannot be added. Choose an avatar, or create one with an icon and colour.")
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
                Text("Bluetooth only works near the band.")
                    .font(.title2.bold())
                VStack(alignment: .leading, spacing: 12) {
                    label("1", "Leave this iPhone in the room, on charge.")
                    label("2", "Do not swipe Nivvi away. Lock the phone normally.")
                    label("3", "If you leave the room, readings stop unless a hub or a second phone is used.")
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
            .navigationTitle("Room setup")
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
    @Binding var metric: HistoryMetric
    let coral: Color
    let teal: Color
    let lavender: Color
    let caption: Color
    let ink: Color
    var lowLimit: Double?
    var highLimit: Double?
    var fahrenheit = false
    @State private var span: TimeInterval = 3600
    @State private var windowEnd: Date?
    @State private var pinchStart: TimeInterval?
    private var domain: ClosedRange<Date> {
        let window = HistoryChartPolicy.window(day: day, span: span, endingAt: windowEnd ?? entries.last?.time ?? day)
        return HistoryChartPolicy.xScale(from: window.lowerBound, to: window.upperBound)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Reading", selection: $metric) {
                Text("Heart rate").tag(HistoryMetric.heartRate)
                Text("Oxygen").tag(HistoryMetric.oxygen)
                Text("Skin").tag(HistoryMetric.skin)
            }.pickerStyle(.segmented)
            Picker("Chart range", selection: $span) {
                Text("1h").tag(3600.0)
                Text("6h").tag(6 * 3600.0)
                Text("24h").tag(0.0)
            }.pickerStyle(.segmented)
            if span > 0 {
                HStack {
                    Button("Earlier") { moveWindow(-1) }
                        .disabled(domain.lowerBound <= Calendar.current.startOfDay(for: day))
                    Spacer()
                    Button("Later") { moveWindow(1) }
                        .disabled(domain.upperBound >= dayEnd)
                }.buttonStyle(.bordered)
            }
            Text(span <= 0 ? "Selected date" : "\(domain.lowerBound.formatted(date: .omitted, time: .shortened)) – \(domain.upperBound.formatted(date: .omitted, time: .shortened))")
                .font(.caption.weight(.semibold)).foregroundStyle(caption).monospacedDigit()
            metricChart(activeMetric, tint: activeTint)
                .frame(minHeight: 360)
        }
        .gesture(
            MagnificationGesture()
                .onChanged { value in
                    if pinchStart == nil { pinchStart = span <= 0 ? 24 * 3600 : span }
                    let next = (pinchStart ?? 3600) / max(0.25, value)
                    span = min(24 * 3600, max(3600, next))
                    if span >= 20 * 3600 { span = 0 }
                    selected = nil
                }
                .onEnded { _ in pinchStart = nil }
        )
        .onChange(of: span) { _ in selected = nil }
        .onChange(of: metric) { _ in selected = nil }
        .onChange(of: day) { _ in selected = nil; windowEnd = nil; span = 3600 }
    }
    private var dayEnd: Date { Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: day))! }
    private func moveWindow(_ direction: Int) {
        windowEnd = domain.upperBound.addingTimeInterval(Double(direction) * (span <= 0 ? 3600 : span))
        selected = nil
    }
    private var activeMetric: HistoryMetric { metric }
    private var activeTint: Color {
        switch activeMetric {
        case .oxygen: return teal
        case .skin: return teal
        case .heartRate: return coral
        }
    }
    private func metricChart(_ metric: HistoryMetric, tint: Color) -> some View {
        let visible = entries.filter { domain.contains($0.time) }
        let limitsApply = metric == .heartRate
        let plotted = span > 60
            ? HistoryChartPolicy.perMinute(visible, metric: metric, low: limitsApply ? lowLimit : nil, high: limitsApply ? highLimit : nil)
            : visible
        let points = HistoryChartPolicy.points(plotted, metric: metric, maximum: 5_000, gap: span > 60 ? 90 : 60)
        var scaleValues = points.map(\.value)
        if limitsApply {
            if let lowLimit { scaleValues.append(lowLimit) }
            if let highLimit { scaleValues.append(highLimit) }
        }
        if metric == .skin {
            scaleValues.append(36.4)
            scaleValues.append(36.7)
        }
        if metric == .skin && fahrenheit { scaleValues = scaleValues.map { $0 * 9 / 5 + 32 } }
        let yDomain = heartScale(HistoryChartPolicy.yScale(
            values: scaleValues,
            floor: metric == .oxygen ? 70 : (metric == .skin ? 28 : 40),
            ceiling: metric == .oxygen ? 100 : (metric == .skin ? 42 : 220),
            pad: metric == .heartRate ? 18 : (metric == .skin ? 0.3 : 2),
            fallback: metric == .oxygen ? 90 : (metric == .skin ? 36 : 80)
        ), metric: metric)
        let latest = points.last
        let shown = selected.flatMap { entry -> (Date, Double)? in
            guard let value = metric.value(entry), domain.contains(entry.time) else { return nil }
            return (entry.time, value)
        } ?? latest.map { ($0.entry.time, $0.value) }
        let stats = HistoryChartPolicy.summary(visible.compactMap { metric.value($0) })
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label(metric == .heartRate ? "Heart rate" : (metric == .skin ? "Skin" : "Oxygen"), systemImage: metric == .heartRate ? "heart.fill" : (metric == .skin ? "thermometer.medium" : "lungs.fill"))
                    .font(.headline).foregroundStyle(shown.map { zoneColor($0.1, plain: tint) } ?? tint)
                Spacer()
                if let shown {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(metric == .skin ? skinText(shown.1) : MetricText.number(shown.1) + (metric == .heartRate ? " bpm" : "%"))
                            .font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(zoneColor(shown.1, plain: tint)).monospacedDigit()
                        Text(readingDetail(shown.1, at: shown.0))
                            .font(.caption.weight(.semibold)).foregroundStyle(caption)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            chartBody(points: points, metric: metric, tint: tint, yDomain: yDomain, visible: visible)
                .frame(minHeight: 300)
            if let stats {
                HStack(spacing: 8) {
                    summaryColumn("Min", stats.min, zoneColor(stats.min, plain: teal), decimals: metric == .skin) { focus(stats.min, in: visible, metric: metric) }
                    summaryColumn("Max", stats.max, zoneColor(stats.max, plain: coral), decimals: metric == .skin) { focus(stats.max, in: visible, metric: metric) }
                    summaryColumn("Median", stats.median, zoneColor(stats.median, plain: ink), decimals: metric == .skin) { focus(stats.median, in: visible, metric: metric) }
                }
            }
        }
    }
    private func skinNumber(_ celsius: Double) -> Double {
        metric == .skin && fahrenheit ? celsius * 9 / 5 + 32 : celsius
    }
    private func skinText(_ celsius: Double) -> String {
        String(format: fahrenheit ? "%.1f°F" : "%.1f°C", skinNumber(celsius))
    }
    private func zoneName(_ value: Double) -> String {
        if activeMetric == .skin { return SkinTemperature.zone(value) }
        guard activeMetric == .heartRate, lowLimit != nil || highLimit != nil else { return "plain" }
        if let highLimit, value > highLimit { return "high" }
        if let lowLimit, value < lowLimit { return "low" }
        return "inside"
    }
    private func zoneColor(_ value: Double, plain: Color) -> Color {
        switch zoneName(value) {
        case "green", "inside": return teal
        case "amber": return .orange
        case "high", "low", "red": return coral
        default: return plain
        }
    }
    private func caption(for time: Date) -> String {
        if selected != nil { return time.formatted(date: .omitted, time: .standard) }
        if span <= 0 && Calendar.current.isDateInToday(day) && Date().timeIntervalSince(time) < 90 { return "Now" }
        return time.formatted(date: .omitted, time: .shortened)
    }
    private func readingDetail(_ value: Double, at time: Date) -> String {
        let clock = caption(for: time)
        if activeMetric == .heartRate {
            if let highLimit, value > highLimit { return "\(MetricText.number(value - highLimit)) above limit · \(clock)" }
            if let lowLimit, value < lowLimit { return "\(MetricText.number(lowLimit - value)) below limit · \(clock)" }
            if lowLimit != nil || highLimit != nil { return "Inside your limits · \(clock)" }
        }
        if activeMetric == .skin {
            switch SkinTemperature.zone(value) {
            case "green": return "Green · \(clock)"
            case "amber": return "Amber · \(clock)"
            default: return "Red · \(clock)"
            }
        }
        return clock
    }
    private func focus(_ value: Double, in visible: [SavedMeasurement], metric: HistoryMetric) {
        guard let match = visible.min(by: {
            let left = metric.value($0).map { abs($0 - value) } ?? .greatestFiniteMagnitude
            let right = metric.value($1).map { abs($0 - value) } ?? .greatestFiniteMagnitude
            return left < right
        }) else { return }
        selected = match
        if span > 0 { windowEnd = match.time.addingTimeInterval(span / 2) }
    }
    private func summaryColumn(_ title: String, _ value: Double, _ color: Color, decimals: Bool = false, choose: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(caption)
            Text(decimals ? String(format: "%.1f", metric == .skin ? skinNumber(value) : value) : MetricText.number(value)).font(.title2.weight(.semibold)).foregroundStyle(color).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(color.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(color.opacity(0.45), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(perform: choose)
        .accessibilityAddTraits(.isButton)
    }
    private func heartScale(_ domain: ClosedRange<Double>, metric: HistoryMetric) -> ClosedRange<Double> {
        guard metric == .heartRate else { return domain }
        let middle = (domain.lowerBound + domain.upperBound) / 2
        let half = max(50, (domain.upperBound - domain.lowerBound) / 2)
        let low = max(40, middle - half)
        var high = min(220, middle + half)
        if high <= low { high = low + 1 }
        return low...high
    }
    private func chartBody(points: [HistoryChartPoint], metric: HistoryMetric, tint: Color, yDomain: ClosedRange<Double>, visible: [SavedMeasurement]) -> some View {
        Group {
            if points.count < 2 {
                Text("Not enough readings in this window.")
                    .font(.caption).foregroundStyle(caption)
                    .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
            } else {
                let runs = lineRuns(points)
                Chart {
                    if metric == .heartRate, let lowLimit, let highLimit, lowLimit < highLimit {
                        RectangleMark(
                            xStart: .value("From", domain.lowerBound),
                            xEnd: .value("To", domain.upperBound),
                            yStart: .value("Low", lowLimit),
                            yEnd: .value("High", highLimit)
                        )
                        .foregroundStyle(teal.opacity(0.20))
                        RuleMark(y: .value("Low limit", lowLimit))
                            .foregroundStyle(teal.opacity(0.95))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        RuleMark(y: .value("High limit", highLimit))
                            .foregroundStyle(coral.opacity(0.95))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                    if metric == .skin {
                        RectangleMark(
                            xStart: .value("From", domain.lowerBound),
                            xEnd: .value("To", domain.upperBound),
                            yStart: .value("Warm from", skinNumber(36.4)),
                            yEnd: .value("Warm to", skinNumber(36.7))
                        )
                        .foregroundStyle(Color.orange.opacity(0.18))
                    }
                    ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                        ForEach(run.points) { point in
                            LineMark(x: .value("Time", point.entry.time), y: .value("Value", skinNumber(point.value)), series: .value("Run", run.series))
                                .foregroundStyle(run.color)
                                .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                                .interpolationMethod(.catmullRom)
                        }
                        if let mark = spellMarker(run) {
                            PointMark(x: .value("Spell", mark.entry.time), y: .value("Spell", skinNumber(mark.value)))
                                .foregroundStyle(run.color)
                                .symbolSize(40)
                        }
                    }
                    if let latest = points.last, selected == nil {
                        RuleMark(x: .value("Latest", latest.entry.time)).foregroundStyle(caption.opacity(0.55))
                        PointMark(x: .value("Latest", latest.entry.time), y: .value("Latest", skinNumber(latest.value))).foregroundStyle(zoneColor(latest.value, plain: tint)).symbolSize(70)
                    }
                    if let entry = selected, let value = metric.value(entry), domain.contains(entry.time) {
                        RuleMark(x: .value("Selected time", entry.time)).foregroundStyle(lavender.opacity(0.85))
                        PointMark(x: .value("Selected time", entry.time), y: .value("Selected value", skinNumber(value))).foregroundStyle(lavender).symbolSize(90)
                    }
                }
                .chartXScale(domain: domain)
                .chartYScale(domain: yDomain)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: span <= 60 ? 4 : (span <= 3600 ? 5 : 4))) { _ in
                        AxisGridLine().foregroundStyle(caption.opacity(0.35))
                        AxisValueLabel().foregroundStyle(caption).font(.caption2)
                    }
                }
                .chartYAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                        AxisGridLine().foregroundStyle(caption.opacity(0.35))
                        AxisValueLabel().foregroundStyle(caption).font(.caption2)
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in pick(at: value.location, proxy: proxy, geometry: geometry, visible: visible, metric: metric) }
                            )
                            .simultaneousGesture(
                                SpatialTapGesture()
                                    .onEnded { event in pick(at: event.location, proxy: proxy, geometry: geometry, visible: visible, metric: metric) }
                            )
                    }
                }
            }
        }
    }
    private struct LineRun {
        var series: String
        var color: Color
        var points: [HistoryChartPoint]
    }
    private func lineRuns(_ points: [HistoryChartPoint]) -> [LineRun] {
        var runs: [LineRun] = []
        var zones: [String] = []
        for point in points {
            let zone = zoneName(point.value)
            let color: Color
            switch zone {
            case "inside", "green": color = teal
            case "amber": color = .orange
            default: color = zone == "plain" ? activeTint : coral
            }
            if let lastZone = zones.last, lastZone == zone, var last = runs.last, last.series.hasPrefix(point.series) {
                last.points.append(point)
                runs[runs.count - 1] = last
            } else if let last = runs.last, last.series.hasPrefix(point.series), let join = last.points.last {
                runs.append(LineRun(series: "\(point.series)-\(runs.count)", color: color, points: [join, point]))
                zones.append(zone)
            } else {
                runs.append(LineRun(series: "\(point.series)-\(runs.count)", color: color, points: [point]))
                zones.append(zone)
            }
        }
        return runs
    }
    private func spellMarker(_ run: LineRun) -> HistoryChartPoint? {
        guard let sample = run.points.last else { return nil }
        switch zoneName(sample.value) {
        case "high", "red", "amber":
            return run.points.max { $0.value < $1.value }
        case "low":
            return run.points.min { $0.value < $1.value }
        default:
            return nil
        }
    }
    private func pick(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy, visible: [SavedMeasurement], metric: HistoryMetric) {
        let frame = geometry[proxy.plotAreaFrame]
        guard frame.contains(location), let date: Date = proxy.value(atX: location.x - frame.minX) else { return }
        let next = HistoryChartPolicy.nearest(visible, at: date, metric: metric)
        if selected?.id != next?.id { selected = next }
    }
}

struct ContentView: View {
    @ObservedObject var monitor: Monitor
    @StateObject private var wifi = WiFiRelay.shared
    @ObservedObject private var family = FamilyRelay.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("nivvi.profile.name") private var childName = ""
    @AppStorage("nivvi.profile.birthDate") private var childBirthDate = 0.0
    @AppStorage("nivvi.profile.gender") private var childGender = "Prefer not to say"
    @AppStorage("nivvi.profile.avatarSymbol") private var avatarSymbol = "star.fill"
    @AppStorage("nivvi.profile.avatarColor") private var avatarColor = "teal"
    @AppStorage("nivvi.skin.fahrenheit") private var skinFahrenheit = false
    @AppStorage("nivvi.host.relation") private var hostRelation = ""
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
    @State private var historySection = 1
    @State private var eventFilter = "All"
    @State private var parentNote = ""
    @State private var showParentNote = false
    @State private var selectedHistoryReading: SavedMeasurement?
    @State private var historyMetric: HistoryMetric = .heartRate
    @State private var editingHost = false
    @State private var hostDraft = ""
    @State private var confirmDeleteHistory = false
    @State private var confirmClearAlerts = false
    @State private var lastSharedAlarm = "none"
    @State private var lastSharedAck = false
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
    private var ink: Color { mode == .night ? .white : Color(red: 23 / 255, green: 43 / 255, blue: 67 / 255) }
    private var muted: Color { mode == .night ? Color.white.opacity(0.82) : Color(red: 82 / 255, green: 101 / 255, blue: 122 / 255) }
    private var cardFill: Color { mode == .night ? Color(red: 0.07, green: 0.16, blue: 0.26) : Color.white }
    private var cardStroke: Color { mode == .night ? Color.white.opacity(0.10) : Color(red: 0.72, green: 0.79, blue: 0.86).opacity(0.7) }
    private var accentMint: Color { mode == .night ? teal : Color(red: 0.05, green: 0.42, blue: 0.45) }
    private var addNoteFill: Color { mode == .night ? coral : Color(red: 0.96, green: 0.72, blue: 0.68) }
    private var addNoteInk: Color { mode == .night ? .white : Color(red: 23 / 255, green: 43 / 255, blue: 67 / 255) }
    private var navSelected: Color { mode == .night ? Color.white.opacity(0.12) : Color(red: 0.863, green: 0.933, blue: 1.0) }
    private var switchOn: Color { teal }
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
    private var localHeartLive: Bool {
        !monitor.staleHeartRateDetected && (
            monitor.connection == .receiving
                || monitor.pulseOximeterRate != nil
                || monitor.verifiedHeartRate != nil
                || monitor.customHeartRateCandidate != nil
        )
    }
    private var watchingFamily: Bool { family.viewingRemote && !localHeartLive }
    private var watchingWifi: Bool { wifi.following && !watchingFamily && !localHeartLive }
    private var heartRateDisplay: String {
        if watchingFamily {
            if let remote = family.liveHeartRate { return remote }
            if let value = family.remote?.snapshot?.heart_rate { return "\(Int(value.rounded())) bpm" }
            return "No reading"
        }
        if watchingWifi, wifi.remoteFresh, let remote = wifi.latest { return remote.heartRate }
        let value = monitor.verifiedHeartRate.map(Double.init) ?? monitor.pulseOximeterRate ?? monitor.customHeartRateCandidate.map(Double.init)
        return value.map { "\(MetricText.number($0)) bpm" } ?? "No reading"
    }
    private var batteryLabel: String {
        if watchingFamily {
            let remote = family.remote?.snapshot?.battery ?? ""
            if family.remote?.snapshot?.charging == true {
                return remote.isEmpty || remote == "—" ? "Charging" : "Charging · \(remote)"
            }
            if !remote.isEmpty && remote != "—" { return remote }
            return "Waiting"
        }
        if watchingWifi, wifi.remoteFresh, let remote = wifi.latest {
            if remote.charging == true {
                let level = remote.battery ?? ""
                return level.isEmpty || level == "—" ? "Charging" : "Charging · \(level)"
            }
            if let level = remote.battery, !level.isEmpty, level != "—" { return level }
        }
        if monitor.wearableCharging {
            return (monitor.battery == "—" || monitor.battery.isEmpty) ? "Charging" : "Charging · \(monitor.battery)"
        }
        if monitor.batteryWarning == .urgent { return "Very low · \(monitor.battery)" }
        if monitor.batteryWarning == .low { return "Low · \(monitor.battery)" }
        if monitor.battery != "—" && !monitor.battery.isEmpty { return monitor.battery }
        return monitor.connection.isConnected || monitor.connection == .reconnecting ? "Waiting" : "Unavailable"
    }
    private var oxygenDisplay: String {
        if watchingFamily {
            if let remote = family.liveOxygen { return remote }
            if let value = family.remote?.snapshot?.oxygen, let shown = OxygenReading.clamp(value) {
                return "\(Int(shown.rounded()))%"
            }
            return "No reading"
        }
        if watchingWifi, wifi.remoteFresh, let remote = wifi.latest { return remote.oxygen }
        let value = monitor.pulseOximeterOxygen ?? monitor.customOxygenCandidate.map(Double.init)
        return value.flatMap(OxygenReading.clamp).map { "\(MetricText.number($0))%" } ?? "No reading"
    }
    private var displayedHistory: [SavedMeasurement] {
        SavedMeasurement.uniquelyIdentified(monitor.history.sorted { $0.time < $1.time })
    }
    private var displayName: String {
        if watchingFamily, let name = family.families.first(where: { $0.id == family.selected })?.child_name, !name.isEmpty {
            return name
        }
        return childName.isEmpty ? "Someone" : childName
    }
    private var mirroringNursery: Bool { (watchingWifi && wifi.remoteFresh) || watchingFamily }
    private var remoteStamp: Date? {
        if watchingWifi, let captured = wifi.latest?.captured { return Date(timeIntervalSince1970: captured) }
        if watchingFamily, let stamped = family.remote?.snapshot?.heart_rate_at ?? family.remote?.snapshot?.captured {
            return Date(timeIntervalSince1970: stamped)
        }
        return nil
    }
    private var remoteBeats: Double? {
        family.remote?.snapshot?.heart_rate ?? wifi.latest.flatMap { Double($0.heartRate.filter { $0.isNumber || $0 == "." }) }
    }
    private var statusCaption: String {
        if monitor.wearableCharging { return "Charging" }
        if localHeartLive && family.signedIn && !family.publishing {
            return "\(monitor.connection.label) · not sharing with family yet"
        }
        if watchingFamily { return family.statusLine }
        if watchingWifi { return wifi.remoteFresh ? "Shared over Wi‑Fi" : wifi.status }
        return monitor.connection.label
    }
    private var nurseryHint: String {
        if BluetoothSignal.isWeak(monitor.signalRSSI) { return "Weak signal — keep this iPhone in the room" }
        if monitor.connection == .reconnecting { return "Stay near the band" }
        return "Leave this iPhone near the band"
    }
    private func syncLiveActivity() {
        let ble = monitor.connection.isConnected || monitor.connection == .reconnecting
        NivviLiveActivityBridge.preferLocalBluetooth = ble
        let wifiLive = watchingWifi && !ble
        let familyLive = watchingFamily && !ble
        let connection: String
        let signal: String
        let hint: String
        if ble {
            connection = monitor.connection.label
            signal = BluetoothSignal.label(monitor.signalRSSI)
            hint = nurseryHint
        } else if wifiLive {
            connection = wifi.remoteFresh ? "Shared over Wi‑Fi" : wifi.status
            signal = "Wi-Fi"
            hint = wifi.remoteFresh ? "" : wifi.status
        } else if familyLive {
            connection = family.remote?.snapshot?.connection ?? "Family sharing"
            signal = "Internet"
            hint = family.statusLine
        } else {
            connection = monitor.connection.label
            signal = BluetoothSignal.label(monitor.signalRSSI)
            hint = ""
        }
        let measured = remoteStamp ?? monitor.lastHeartRateUpdate
        let alarm: String
        if ble {
            alarm = monitor.alarmKind?.rawValue ?? ""
        } else if familyLive {
            let remoteAlarm = family.remote?.snapshot?.alarm ?? ""
            alarm = remoteAlarm == "high" || remoteAlarm == "low" ? remoteAlarm : ""
        } else if wifiLive {
            let remoteAlarm = wifi.latest?.alarm ?? ""
            alarm = remoteAlarm == "high" || remoteAlarm == "low" ? remoteAlarm : ""
        } else {
            alarm = ""
        }
        let stale = measured == nil || (ble && monitor.staleHeartRateDetected) || (familyLive && family.linkState != .live) || (wifiLive && !wifi.remoteFresh)
        NivviLiveActivityBridge.sync(
            title: displayName,
            heartRate: heartRateDisplay,
            oxygen: oxygenDisplay,
            connection: connection,
            signal: signal,
            nurseryHint: hint,
            monitoring: ble || wifi.following || watchingFamily,
            measuredAt: measured ?? Date(timeIntervalSince1970: 0),
            stale: stale,
            alarm: alarm
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
            battery: monitor.battery,
            history: Array(monitor.history.suffix(120).map { FamilySample(t: $0.time.timeIntervalSince1970, hr: $0.heartRateValue, o2: $0.oxygenValue, sk: $0.skinCelsius) }),
            acknowledged: monitor.alarmAcknowledged,
            skin: monitor.skinCelsius,
            alerts: monitor.heartAlertsToShare()
        )
    }
    private var shareAlarmKind: String {
        if let kind = monitor.alarmKind { return kind.rawValue }
        if monitor.staleHeartRateDetected { return "sensor" }
        return "none"
    }
    private func persistSharedHistory() {
        if watchingFamily {
            var rows = family.trail
            if let samples = family.remote?.snapshot?.history {
                rows.append(contentsOf: samples.map {
                    SavedMeasurement.mapped(time: Date(timeIntervalSince1970: $0.t), heartRate: $0.hr, oxygen: $0.o2, source: "family-share", skinCelsius: $0.sk)
                })
            }
            monitor.ingestShared(rows)
            if let alerts = family.remote?.snapshot?.alerts { monitor.ingestSharedAlerts(alerts) }
        }
        if wifi.following {
            var rows = wifi.trail
            if let samples = wifi.latest?.history {
                rows.append(contentsOf: samples.map {
                    SavedMeasurement.mapped(time: Date(timeIntervalSince1970: $0.t), heartRate: $0.hr, oxygen: $0.o2, source: "wifi-share", skinCelsius: $0.sk)
                })
            }
            monitor.ingestShared(rows)
            if let alerts = wifi.latest?.alerts { monitor.ingestSharedAlerts(alerts) }
        }
    }
    private func applyShareAlert() {
        if watchingFamily, let snap = family.remote?.snapshot {
            let alarm = snap.alarm
            noteSharedAlert(alarm: alarm, acknowledged: snap.acknowledged == true, heartRate: snap.heart_rate.map { Int($0.rounded()) }, catchup: family.alarmCatchup)
            if family.alarmCatchup {
                if alarm == "none" { monitor.endShareAlert() }
                return
            }
            if alarm == "none" { monitor.endShareAlert(); return }
            if snap.acknowledged == true { monitor.silenceAlarm() }
            monitor.beginShareAlert(sensor: alarm == "sensor")
            return
        }
        if watchingWifi, let snap = wifi.latest, Date().timeIntervalSince1970 - snap.captured < 90 {
            let alarm = snap.alarm ?? "none"
            noteSharedAlert(alarm: alarm, acknowledged: snap.acknowledged == true, heartRate: remoteBeats.flatMap { $0 > 0 ? Int($0.rounded()) : nil }, catchup: false)
            if alarm == "none" { monitor.endShareAlert(); return }
            guard wifi.playAlerts else { return }
            if snap.acknowledged == true { monitor.silenceAlarm() }
            monitor.beginShareAlert(sensor: alarm == "sensor")
            return
        }
        lastSharedAlarm = "none"
        lastSharedAck = false
        monitor.endShareAlert()
    }
    private func noteSharedAlert(alarm: String, acknowledged: Bool, heartRate: Int?, catchup: Bool) {
        if catchup {
            lastSharedAlarm = alarm
            lastSharedAck = acknowledged
            return
        }
        if let event = SharedAlertLog.event(previous: lastSharedAlarm, next: alarm, wasAcknowledged: lastSharedAck, acknowledged: acknowledged) {
            monitor.recordEvent(kind: event.kind, title: event.title, detail: event.detail, heartRate: heartRate == 0 ? nil : heartRate)
        }
        lastSharedAlarm = alarm
        lastSharedAck = alarm == "none" ? false : (acknowledged || lastSharedAck)
    }
    private func acknowledgeEverywhere() {
        monitor.silenceAlarm()
        wifi.sendAck()
        Task { await family.acknowledgeAlarm() }
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
                animate: scenePhase == .active && !reduceMotion
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
            VStack(spacing: 0) {
                header
                if monitor.criticalAlertActive && !alarmOwnsScreen { alarmBanner.padding(.horizontal, 20) }
                ScrollView(showsIndicators: false) {
                    selectedTab
                    .padding(.horizontal, 20).padding(.bottom, 110)
                    .modifier(AtmosphereScroll(offset: $skyOffset))
                }
                .coordinateSpace(name: "nivvi-sky")
                bottomBar
            }
            .zIndex(1)
            if alarmOwnsScreen { alarmTakeover.zIndex(2) }
        }
        .preferredColorScheme(mode == .night ? .dark : .light)
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                ScrollView { settings.padding(20) }
                    .background((mode == .night ? Color(red: 0.02, green: 0.13, blue: 0.23) : Color(red: 0.969, green: 0.980, blue: 1.0)).ignoresSafeArea())
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
            family.startWatching()
            UIApplication.shared.isIdleTimerDisabled = wifi.hosting || wifi.following || monitor.connection.isConnected || family.viewingRemote
        }
        .onChange(of: scenePhase) { phase in
            wifi.revive()
            monitor.refreshBackgroundHold()
            if phase == .active { family.resumeForeground() }
        }
        .sheet(isPresented: $showProfile) {
            ProfileSetupView(name: childName, birthDate: birthDate, gender: childGender, avatarSymbol: avatarSymbol, avatarColor: avatarColor) { name, date, gender, symbol, color in
                childName = name
                childBirthDate = date.timeIntervalSince1970
                childGender = gender
                avatarSymbol = symbol
                avatarColor = color
                if family.isOwner {
                    family.perform { try await family.pushProfile() }
                }
                if !nurseryAcknowledged { showNursery = true }
                return true
            }
        }
        .sheet(isPresented: $showNursery) {
            NurserySetupView { nurseryAcknowledged = true }
        }
        .onChange(of: wifi.hosting) { _ in
            publishWiFiShare()
            monitor.refreshBackgroundHold()
            UIApplication.shared.isIdleTimerDisabled = wifi.hosting || wifi.following || monitor.connection.isConnected || family.viewingRemote
        }
        .onChange(of: wifi.following) { on in
            if on { monitor.requestNotificationPermission() }
            applyShareAlert()
            monitor.refreshBackgroundHold()
            syncLiveActivity()
            UIApplication.shared.isIdleTimerDisabled = wifi.hosting || wifi.following || monitor.connection.isConnected || family.viewingRemote
        }
        .onChange(of: monitor.connection) { _ in
            publishWiFiShare(); syncLiveActivity()
            UIApplication.shared.isIdleTimerDisabled = wifi.hosting || wifi.following || monitor.connection.isConnected || family.viewingRemote
        }
        .onChange(of: monitor.verifiedHeartRate) { _ in publishWiFiShare(); syncLiveActivity() }
        .onChange(of: monitor.pulseOximeterOxygen) { _ in publishWiFiShare(); syncLiveActivity() }
        .onChange(of: monitor.customHeartRateCandidate) { _ in publishWiFiShare(); syncLiveActivity() }
        .onChange(of: monitor.customOxygenCandidate) { _ in publishWiFiShare(); syncLiveActivity() }
        .onChange(of: monitor.signalRSSI) { _ in syncLiveActivity() }
        .onChange(of: monitor.alarmKind) { _ in publishWiFiShare(); syncLiveActivity() }
        .onChange(of: monitor.alarmAcknowledged) { _ in publishWiFiShare() }
        .onChange(of: wifi.inboundAck) { _ in
            if wifi.consumeInboundAck() { monitor.silenceAlarm() }
        }
        .onChange(of: family.inboundAck) { _ in
            if family.consumeInboundAck() { monitor.silenceAlarm() }
        }
        .onChange(of: family.viewingRemote) { on in
            if on {
                monitor.requestNotificationPermission()
                Task { try? await family.notifications() }
            }
            applyShareAlert()
            monitor.refreshBackgroundHold()
        }
        .onChange(of: family.publishing) { _ in monitor.refreshBackgroundHold() }
        .onChange(of: family.bandHandover) { notice in
            let text = notice.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            family.bandHandover = ""
            monitor.releaseForHandover(text)
        }
        .onChange(of: monitor.staleHeartRateDetected) { _ in publishWiFiShare(); syncLiveActivity() }
        .onChange(of: monitor.wearableCharging) { _ in publishWiFiShare() }
        .onChange(of: family.remoteFetched) { _ in
            applyShareAlert()
            persistSharedHistory()
            syncLiveActivity()
            UIApplication.shared.isIdleTimerDisabled = wifi.hosting || wifi.following || monitor.connection.isConnected || family.viewingRemote
        }
        .onChange(of: wifi.latest) { _ in
            applyShareAlert()
            persistSharedHistory()
            syncLiveActivity()
        }
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
        .onChange(of: tab) { now in
            if now == 1 { monitor.selectHistoryDay(monitor.selectedHistoryDay) }
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

    @ViewBuilder
    private var header: some View {
        if tab == 0 { liveHeader } else { compactHeader }
    }

    private var liveHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                avatarBadge(size: 52, symbolSize: .title2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(Calendar.current.component(.hour, from: Date()) >= 12 && mode == .day ? "Hello," : mode.greeting).font(.subheadline.weight(.semibold)).foregroundStyle(muted)
                    Text(displayName).font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(ink)
                }
                Spacer()
                headerButtons
            }
            HStack(spacing: 10) {
                Circle().fill(situationColor).frame(width: 11, height: 11)
                Text(situationLine).font(.subheadline.weight(.bold)).foregroundStyle(ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Spacer()
                Text(mode == .day ? "Day" : "Night").font(.caption.weight(.semibold))
                    .foregroundStyle(mode == .day ? ink : .white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(mode == .day ? Color.white.opacity(0.78) : Color.white.opacity(0.16))
                    .clipShape(Capsule())
            }
            if !ageText.isEmpty { Text(childGender == "Prefer not to say" ? ageText : "\(ageText) · \(childGender)").font(.caption).foregroundStyle(muted) }
            hostPicker
            if family.signedIn { familySendBanner }
            if monitor.lowPowerMode {
                Text("Low Power Mode is on. Turn it off so Nivvi can keep reading overnight.")
                    .font(.caption.weight(.semibold)).foregroundStyle(coral)
            }
            if watchingWifi && !wifi.remoteFresh {
                Text(wifi.status)
                    .font(.caption.weight(.semibold)).foregroundStyle(coral)
            }
        }.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 8)
    }

    @ViewBuilder private var familySendBanner: some View {
        if family.publishing {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let sent = family.lastUpload {
                    let age = Int(context.date.timeIntervalSince(sent))
                    Text(age < 20 ? "Family send OK · \(age)s ago" : "Family send stalled · \(age)s ago")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(age < 20 ? accentMint : coral)
                } else {
                    Text(family.message.isEmpty ? "Starting family send…" : family.message)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(coral)
                }
            }
        } else if localHeartLive {
            Text("Band is live here. Family won’t see it until you tap I’m with \(displayName) — start monitoring.")
                .font(.caption.weight(.semibold))
                .foregroundStyle(coral)
        }
    }

    private var compactHeader: some View {
        HStack(spacing: 12) {
            avatarBadge(size: 36, symbolSize: .subheadline)
            Text(compactTitle).font(.title2.bold()).foregroundStyle(ink)
            Spacer(minLength: 8)
            headerButtons
        }
        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 6)
    }

    private var compactTitle: String {
        switch tab {
        case 1: return monitor.selectedHistoryDay.formatted(date: .abbreviated, time: .omitted)
        case 2: return "Alerts"
        case 3: return "Device"
        default: return displayName
        }
    }

    private var headerButtons: some View {
        HStack(spacing: 8) {
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill").font(.title3).foregroundStyle(ink)
                    .frame(width: 44, height: 44).background(cardFill).clipShape(Circle())
            }
            .accessibilityLabel("Settings")
            Button { manualMode = manualMode == nil ? (mode == .night ? .day : .night) : nil } label: {
                Image(systemName: mode.symbol).font(.title3).foregroundStyle(mode == .night ? lavender : Color(red: 0.85, green: 0.62, blue: 0.16))
                    .frame(width: 44, height: 44).background(cardFill).clipShape(Circle())
            }
            .accessibilityLabel("Day or night mode")
        }
    }

    private func avatarBadge(size: CGFloat, symbolSize: Font) -> some View {
        ZStack {
            Circle().fill(avatarTint.opacity(0.35)).frame(width: size, height: size)
            Image(systemName: avatarSymbolName).font(symbolSize).fontWeight(.semibold).foregroundStyle(avatarTint)
        }
        .accessibilityLabel("Profile avatar")
    }

    private var alarmOwnsScreen: Bool {
        if monitor.alarmAcknowledged { return false }
        if monitor.alarmActive { return true }
        let shared = family.remote?.snapshot?.alarm ?? wifi.latest?.alarm ?? ""
        return monitor.shareAlertActive && (shared == "high" || shared == "low")
    }
    private var alarmTakeover: some View {
        let high = monitor.alarmKind == .high || family.remote?.snapshot?.alarm == "high" || wifi.latest?.alarm == "high"
        return VStack(spacing: 22) {
            Spacer()
            Text(displayName).font(.title2.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
            Text(high ? "Heart rate is high" : "Heart rate is low")
                .font(.title.weight(.bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text(heroHeartRate)
                .font(.system(size: 92, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .minimumScaleFactor(0.4)
                .lineLimit(1)
            Text("bpm").font(.title2.weight(.semibold)).foregroundStyle(.white.opacity(0.8))
            Text("Stay with them and follow their care plan.")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Spacer()
            Button("I heard it") { acknowledgeEverywhere() }
                .font(.title2.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(.white)
                .foregroundStyle(coral)
                .clipShape(RoundedRectangle(cornerRadius: 18))
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(coral.ignoresSafeArea())
    }
    private var situationLine: String {
        if monitor.alarmActive && !monitor.alarmAcknowledged { return "Heart rate alarm. Stay with them." }
        if monitor.wearableCharging { return "The band is charging." }
        if localHeartLive {
            if family.publishing {
                let who = FamilyRelation.display(hostRelation) ?? "You"
                return who == "You" ? "You are monitoring." : "\(who) is monitoring."
            }
            if family.signedIn { return "The band is connected here. Family cannot see it yet." }
            return "You are monitoring."
        }
        if watchingFamily {
            let who = FamilyRelation.display(family.remote?.snapshot?.host_relation) ?? "Family"
            switch family.linkState {
            case .live: return "\(who) is monitoring."
            case .sensorDisconnected: return "The band is not connected."
            default: return "Not receiving. Check the phone next to the band."
            }
        }
        if watchingWifi {
            return wifi.remoteFresh ? "You are watching on this Wi‑Fi." : "The band is not connected."
        }
        if monitor.connection == .idle || monitor.connection == .bluetoothOff { return "The band is not connected." }
        return monitor.connection.label
    }
    private var situationColor: Color {
        if situationLine.contains("not connected") || situationLine.contains("Not receiving") || situationLine.contains("cannot see") || situationLine.contains("alarm") {
            return coral
        }
        if situationLine.contains("charging") { return .orange }
        return accentMint
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
                        Button("Heard it") { acknowledgeEverywhere() }.buttonStyle(.bordered).tint(.white)
                    } else if !monitor.alarmAcknowledged {
                        Button("Acknowledge") { acknowledgeEverywhere() }.buttonStyle(.bordered).tint(.white)
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
            return "Shared from \(FamilyRelation.display(wifi.latest?.hostRelation) ?? "family") on this Wi‑Fi. Limits are set on that phone."
        }
        return monitor.staleHeartRateDetected ? (monitor.alarmAcknowledged ? "Acknowledged · repeated reading still needs checking." : "Repeated heart-rate value detected. Check sensor contact.") : (monitor.alarmAcknowledged ? "Acknowledged · waiting for a fresh in-range reading." : "Stay with them and follow their care plan.")
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
            if !family.viewingRemote && (BluetoothSignal.isWeak(monitor.signalRSSI) || monitor.connection == .reconnecting) {
                Text(nurseryHint)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(coral)
                Button("Room setup") { showNursery = true }
                    .font(.caption.weight(.semibold))
            }
            HStack(spacing: 12) {
                Button { showParentNote = true } label: {
                    Text("Add note").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(14)
                        .background(addNoteFill).foregroundStyle(addNoteInk).clipShape(RoundedRectangle(cornerRadius: 16))
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
            if !mirroringNursery { readinessPanel }
        }
    }

    private var hostPicker: some View {
        HStack {
            Text("This phone is").font(.subheadline.weight(.semibold)).foregroundStyle(ink)
            Spacer()
            Button {
                hostDraft = FamilyRelation.display(hostRelation) ?? ""
                editingHost = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "person.fill")
                    Text(FamilyRelation.display(hostRelation) ?? "Type")
                        .font(.title3.weight(.bold))
                    Image(systemName: "pencil").font(.caption.weight(.bold))
                }
                .foregroundStyle(accentMint)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(accentMint.opacity(0.16))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Who is using this phone")
            .alert("This phone is", isPresented: $editingHost) {
                TextField("Name", text: $hostDraft)
                Button("Save") {
                    hostRelation = String(hostDraft.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Type who is using this phone. Family will see this name.")
            }
        }
    }

    private var latestNote: SavedEvent? {
        monitor.events.filter { $0.kind == "note" }.max { $0.time < $1.time }
    }
    private var fiveMinuteReadings: [SavedMeasurement] {
        let start = Date().addingTimeInterval(-120)
        let source: [SavedMeasurement] = {
            if watchingWifi, wifi.remoteFresh, !wifi.trail.isEmpty { return wifi.trail }
            if watchingFamily, !family.trail.isEmpty { return family.trail }
            if watchingFamily, let samples = family.remote?.snapshot?.history, !samples.isEmpty {
                return samples.map {
                    SavedMeasurement.mapped(
                        time: Date(timeIntervalSince1970: $0.t),
                        heartRate: $0.hr,
                        oxygen: $0.o2,
                        source: "family-share"
                    )
                }
            }
            return monitor.liveTrace
        }()
        return source.filter { sample in
            sample.time >= start && (sample.heartRateValue ?? 0) > 0
        }
    }
    private var liveChartCaption: String {
        if watchingFamily {
            switch family.linkState {
            case .live: return "Live · internet"
            case .hostStale: return "Stale · not live"
            case .sensorDisconnected: return "Sensor disconnected"
            case .viewerOffline: return "Offline · not live"
            case .idle: return "Family share"
            }
        }
        if watchingWifi { return wifi.remoteFresh ? "Live · Wi‑Fi" : "Wi‑Fi stale · not live" }
        if monitor.staleHeartRateDetected { return "Not live" }
        return "Live"
    }
    private var fiveMinuteChart: some View {
        let points = HistoryChartPolicy.points(fiveMinuteReadings, metric: .heartRate)
        let now = Date()
        let earliest = fiveMinuteReadings.map(\.time).min() ?? now.addingTimeInterval(-120)
        let xDomain = HistoryChartPolicy.xScale(from: max(now.addingTimeInterval(-120), earliest.addingTimeInterval(-4)), to: max(now, earliest.addingTimeInterval(1)))
        let yDomain = HistoryChartPolicy.yScale(values: points.map(\.value), floor: 40, ceiling: 220, pad: 8, fallback: 80)
        return VStack(alignment: .leading, spacing: 4) {
            Text(liveChartCaption).font(.caption.weight(.bold)).foregroundStyle(muted)
            if points.count < 2 {
                Text("Waiting for live readings.")
                    .font(.caption).foregroundStyle(muted)
            } else {
                Chart {
                    ForEach(points) { point in
                        LineMark(x: .value("Time", point.entry.time), y: .value("bpm", point.value), series: .value("Continuous segment", point.series))
                            .foregroundStyle(coral)
                    }
                }
                .chartXScale(domain: xDomain)
                .chartYScale(domain: yDomain)
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
                .accessibilityLabel("Heart-rate chart for the last two minutes")
            }
        }
    }
    private var liveHero: some View {
        panel {
            VStack(alignment: .leading, spacing: 8) {
                Text("Heart rate").font(.caption.weight(.bold)).tracking(1.1).foregroundStyle(muted)
                HStack(alignment: .center, spacing: 12) {
                    PulsingHeart(
                        beatsPerMinute: mirroringNursery ? remoteBeats : (monitor.staleHeartRateDetected ? nil : (monitor.verifiedHeartRate.map(Double.init) ?? monitor.pulseOximeterRate ?? monitor.customHeartRateCandidate.map(Double.init))),
                        tint: monitor.staleHeartRateDetected && !mirroringNursery ? coral : Color(red: 0.93, green: 0.38, blue: 0.42)
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
                .contentShape(Rectangle())
                .onTapGesture { openHistory(.heartRate) }
                .accessibilityElement(children: .combine)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(readingAge(mirroringNursery ? remoteStamp : monitor.lastHeartRateUpdate, now: context.date))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle((family.viewingRemote && family.linkState != .live) || (monitor.staleHeartRateDetected && !mirroringNursery) ? coral : accentMint)
                }
                if watchingWifi && wifi.remoteFresh {
                    Text(FamilyRelation.sharedFrom(wifi.latest?.hostRelation, wifi: true)).font(.caption).foregroundStyle(accentMint)
                } else if watchingFamily {
                    Text(family.statusLine).font(.caption).foregroundStyle(family.linkState == .live ? accentMint : coral)
                }
                fiveMinuteChart
                    .contentShape(Rectangle())
                    .onTapGesture { openHistory(.heartRate) }
                if let note = latestNote {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Latest note").font(.caption.weight(.bold)).foregroundStyle(muted)
                        Text(note.detail).font(.subheadline).foregroundStyle(ink)
                        Text(note.time.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(muted)
                    }
                }
                if mirroringNursery || monitor.profile == .custom || monitor.profile.hasPulseOximeter {
                    Divider().overlay(muted.opacity(0.25))
                    HStack {
                        Label("Oxygen", systemImage: "lungs.fill").foregroundStyle(accentMint)
                        Spacer()
                        Text(oxygenDisplay).font(.title3.bold()).foregroundStyle(accentMint)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { openHistory(.oxygen) }
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(readingAge(mirroringNursery ? remoteStamp : monitor.lastOxygenUpdate, now: context.date)).font(.caption).foregroundStyle(muted)
                    }
                }
                if batteryLabel != "Unavailable" {
                    HStack {
                        Label("Band battery", systemImage: "battery.100").foregroundStyle(muted)
                        Spacer()
                        Text(batteryLabel).font(.headline).foregroundStyle(ink)
                    }
                }
                if let skin = displayedSkin {
                    Button {
                        openHistory(.skin)
                    } label: {
                        HStack {
                            Label("Skin", systemImage: "thermometer.medium").foregroundStyle(skinColor(skin))
                            Spacer()
                            Text(skinReading(skin)).font(.headline).foregroundStyle(skinColor(skin)).monospacedDigit()
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens skin temperature history")
                }
            }
        }
    }
    private var displayedSkin: Double? {
        if watchingFamily { return family.remote?.snapshot?.skin }
        if watchingWifi { return wifi.latest?.skinCelsius }
        return monitor.skinCelsius
    }
    private func skinReading(_ celsius: Double) -> String {
        skinFahrenheit ? String(format: "%.1f°F", celsius * 9 / 5 + 32) : String(format: "%.1f°C", celsius)
    }
    private func openHistory(_ metric: HistoryMetric) {
        historyMetric = metric
        tab = 1
    }
    private func skinColor(_ celsius: Double) -> Color {
        switch SkinTemperature.zone(celsius) {
        case "amber": return .orange
        case "red": return coral
        default: return accentMint
        }
    }
    private var heroHeartRate: String {
        if heartRateDisplay == "No reading" { return "—" }
        return heartRateDisplay.replacingOccurrences(of: " bpm", with: "")
    }

    private var supportiveCard: some View {
        panel { VStack(alignment: .leading, spacing: 10) {
            Label(monitor.criticalAlertActive ? "One step at a time" : "Here when you need it", systemImage: "heart.text.clipboard").font(.headline)
            Text(monitor.criticalAlertActive ? "Take a breath and stay close. Check how they are and follow the plan from their care team." : "You can add a note about how they are doing. Small observations can help you explain what happened to their care team.").font(.subheadline)
            if monitor.criticalAlertActive {
                Text("If your care team has taught you to check their heart rate with a stethoscope, use their instructions. Do not delay urgent help to take a reading.").font(.caption)
                Text("If they are seriously unwell, seek emergency help immediately.").font(.caption.bold())
            }
            DisclosureGroup("Checking a reading") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Follow the pulse-check method and action limits your care team has given you. A stethoscope check is not a diagnosis. If symptoms worry you, contact the care team; seek emergency help if they are seriously unwell.").font(.caption)
                    Link("GOSH: understanding SVT", destination: URL(string: "https://www.gosh.nhs.uk/conditions-and-treatments/conditions-we-treat/supraventricular-tachycardia/")!).font(.caption)
                }
            }
            Text("General guidance only · not medical advice").font(.caption2).foregroundStyle(muted)
        } }
    }
    private var history: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button { shiftHistory(-1) } label: {
                    Image(systemName: "chevron.left").font(.headline)
                        .frame(width: 44, height: 44).background(cardFill).clipShape(Circle())
                }
                .accessibilityLabel("Previous day")
                VStack(spacing: 4) {
                    Text(monitor.selectedHistoryDay.formatted(Date.FormatStyle().weekday(.wide).month().day()))
                        .font(.title3.bold())
                        .foregroundStyle(ink)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.75)
                        .lineLimit(1)
                    DatePicker("Choose day", selection: Binding(get: { monitor.selectedHistoryDay }, set: {
                        historySpan = 1
                        monitor.selectHistoryDay($0)
                    }), in: ...Date(), displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    .tint(accentMint)
                    .id(monitor.selectedHistoryDay)
                }
                .frame(maxWidth: .infinity)
                Button { shiftHistory(1) } label: {
                    Image(systemName: "chevron.right").font(.headline)
                        .frame(width: 44, height: 44).background(cardFill).clipShape(Circle())
                }
                .disabled(Calendar.current.isDateInToday(monitor.selectedHistoryDay))
                .accessibilityLabel("Next day")
                Button { showParentNote = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Add note")
            }
            if displayedHistory.contains(where: { $0.source == "family-share" || $0.source == "wifi-share" }) {
                Text("Includes readings this iPhone received while following. About one card every 30 seconds, same as that phone’s History. They stay here for 30 days.")
                    .font(.caption).foregroundStyle(muted)
            }
            if displayedHistory.isEmpty {
                panel {
                    Text("No readings this day.")
                    if family.viewingRemote || wifi.following {
                        Text("Shared readings are saved on this iPhone while you follow. They stay here for 30 days.")
                            .font(.caption).foregroundStyle(muted)
                    }
                }
            } else {
                panel {
                    HistoryChartsView(entries: displayedHistory, day: monitor.selectedHistoryDay, selected: $selectedHistoryReading, metric: $historyMetric, coral: coral, teal: accentMint, lavender: stamp, caption: muted, ink: ink, lowLimit: monitor.alarmSettings.lowEnabled ? monitor.alarmSettings.lowThreshold.map(Double.init) : nil, highLimit: monitor.alarmSettings.highEnabled ? monitor.alarmSettings.highThreshold.map(Double.init) : nil, fahrenheit: skinFahrenheit)
                        .id(Calendar.current.startOfDay(for: monitor.selectedHistoryDay))
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(Array(displayedHistory.suffix(15).reversed())) { sample in
                        VStack(spacing: 4) {
                            Text(readingClock(sample.time)).font(.caption2.monospacedDigit().weight(.semibold)).foregroundStyle(muted)
                            Text(sample.heartRateValue.map { MetricText.number($0) } ?? "—").font(.title3.bold().monospacedDigit()).foregroundStyle(coral)
                            Text("bpm").font(.caption2.weight(.semibold)).foregroundStyle(muted)
                            if let o2 = sample.oxygenValue {
                                Text("O₂ \(MetricText.number(o2))%").font(.caption2.weight(.semibold)).foregroundStyle(accentMint)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(cardFill)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
            if let error = monitor.historyError { Text(error).foregroundStyle(coral) }
            if !monitor.recordedDays.isEmpty {
                DisclosureGroup("Export") {
                    VStack(alignment: .leading, spacing: 10) {
                        Button("Readings CSV") { historyExport = monitor.exportHistory() }
                        if let url = historyExport { ShareLink("Share readings", item: url) }
                        Button("Events CSV") { eventsExport = monitor.exportEvents() }
                        if let url = eventsExport { ShareLink("Share events", item: url) }
                        Button("Report") { reportExport = monitor.exportReport() }
                        if let url = reportExport { ShareLink("Share report", item: url) }
                        Button("Delete all history", role: .destructive) { confirmDeleteHistory = true }
                    }.padding(.top, 8)
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
            Text(readingClock(time)).font(.system(size: 24, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(tint)
            Spacer()
            Text(time.formatted(date: .abbreviated, time: .omitted)).font(.caption.weight(.bold)).foregroundStyle(muted)
        }
    }
    private func readingClock(_ time: Date) -> String {
        time.formatted(Date.FormatStyle().hour().minute().second())
    }

    private var alerts: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Filter", selection: $alertFilter) {
                Text("All").tag("All")
                Text("Heart rate").tag("Heart rate")
                Text("Connection").tag("Connection")
            }.pickerStyle(.segmented)
            let items = alertItems
            if !monitor.recentAlerts().isEmpty {
                Button("Clear recent alerts", role: .destructive) { confirmClearAlerts = true }
                    .font(.subheadline.weight(.semibold))
            }
            if items.isEmpty { panel { Text(alertFilter == "Connection" ? "No connection events in the last 7 days." : "No high or low heart-rate alerts in the last 7 days.") } }
            ForEach(items) { event in
                if event.kind == "connection" { connectionEventCard(event) }
                else { heartEventCard(event) }
            }
        }
        .confirmationDialog("Clear heart-rate and connection alerts from the last 7 days? Notes and history readings stay on this iPhone.", isPresented: $confirmClearAlerts, titleVisibility: .visible) {
            Button("Clear recent alerts", role: .destructive) { monitor.clearRecentAlerts() }
        }
    }
    private func heartEventCard(_ event: SavedEvent) -> some View {
        let restored = event.title == "Heart rate back to normal"
        let tint: Color = restored ? Color(red: 0.45, green: 0.95, blue: 0.65) : coral
        return VStack(alignment: .leading, spacing: 9) {
            timestamp(event.time, tint: tint)
            Label(event.title, systemImage: restored ? "checkmark.circle.fill" : "bell.fill")
                .font(.headline).foregroundStyle(restored ? tint : ink)
            Text(event.detail).font(.subheadline).foregroundStyle(restored ? tint : muted)
            if let bpm = event.heartRate { Text("\(bpm) bpm").font(.title3.bold()).foregroundStyle(tint) }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                cardFill
                if restored { Color.green.opacity(mode == .night ? 0.22 : 0.16) }
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(restored ? Color.green.opacity(0.55) : coral.opacity(0.28), lineWidth: 1))
    }
    private func connectionEventCard(_ event: SavedEvent) -> some View {
        let lost = event.title.localizedCaseInsensitiveContains("lost") || event.title.localizedCaseInsensitiveContains("unavailable") || event.title.localizedCaseInsensitiveContains("disconnected")
        let tint: Color = lost ? coral : teal
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: lost ? "antenna.radiowaves.left.and.right.slash" : "wave.3.right")
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.subheadline.weight(.semibold)).foregroundStyle(ink)
                Text(event.time.formatted(date: .abbreviated, time: .shortened)).font(.caption.monospacedDigit()).foregroundStyle(muted)
            }
            Spacer()
        }
        .padding(14)
        .background(cardFill)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(tint.opacity(0.28), lineWidth: 1))
    }
    private var alertItems: [SavedEvent] {
        let relevant = monitor.recentAlerts()
        switch alertFilter {
        case "Heart rate":
            return relevant.filter { $0.kind == "critical" || $0.kind == "alarm" }
        case "Connection":
            return relevant.filter { $0.kind == "connection" }
        default:
            return relevant
        }
    }
    private var device: some View {
        VStack(alignment: .leading, spacing: 16) {
            panel {
                VStack(alignment: .leading, spacing: 8) {
                    Text("CONNECTED MONITOR").font(.caption.bold()).foregroundStyle(muted)
                    Text(monitor.connectedMonitorName).font(.headline)
                    HStack(spacing: 8) {
                        Circle()
                            .fill(monitor.connection == .receiving ? accentMint : (connected ? accentMint.opacity(0.55) : muted))
                            .frame(width: 8, height: 8)
                        Text(monitor.connection.label).foregroundStyle(connected ? accentMint : muted)
                    }
                    if monitor.connection.isConnected {
                        Text("Signal: \(BluetoothSignal.label(monitor.signalRSSI))").font(.caption).foregroundStyle(muted)
                    }
                    Text(monitor.profile.readingSummary).font(.subheadline)
                }
            }
            HStack(spacing: 14) { metric("Battery", batteryLabel); metric("Mode", mode.rawValue) }
            Button { monitor.active ? monitor.stop() : monitor.scan() } label: { Text(monitor.active ? "Disconnect" : (monitor.isScanning ? "Scanning…" : "Scan for devices")).font(.headline).frame(maxWidth: .infinity).padding(17) }.buttonStyle(.borderedProminent).tint(coral).disabled(monitor.isScanning)
            if !monitor.active {
                ForEach(sortedDevices, id: \.identifier) { p in
                    HStack(spacing: 10) {
                        Button { captureRequest = CaptureRequest(peripheral: p) } label: {
                            HStack { VStack(alignment: .leading) { Text(monitor.deviceNames[p.identifier] ?? p.name ?? "Unnamed Bluetooth device").font(.headline); Text("Tap to connect").font(.caption).foregroundStyle(muted); if let rssi = monitor.deviceRSSI[p.identifier] { Text("Signal: \(BluetoothSignal.label(rssi))").font(.caption).foregroundStyle(muted) } }; Spacer(); Image(systemName: "chevron.right") }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                        }.buttonStyle(.bordered).disabled(monitor.active)
                        Button { toggleFavourite(p) } label: { Image(systemName: isFavourite(p) ? "star.fill" : "star").foregroundStyle(isFavourite(p) ? .yellow : muted).padding(12) }.accessibilityLabel(isFavourite(p) ? "Remove favourite device" : "Favourite device")
                    }
                }
                Toggle("Show all nearby Bluetooth devices", isOn: $monitor.showAllDevices)
                    .disabled(monitor.isScanning)
                Text("Leave this off unless your band does not appear in the list.")
                    .font(.caption).foregroundStyle(muted)
            }
            DisclosureGroup("Diagnostics") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(monitor.status).font(.caption).fixedSize(horizontal: false, vertical: true)
                    Text(monitor.measurementStatus).font(.caption).foregroundStyle(muted)
                    if let time = monitor.lastSample {
                        Text("Last packet \(time.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(muted)
                    }
                    if let url = monitor.files.first {
                        ShareLink(item: url) { Label("Share capture log", systemImage: "square.and.arrow.up") }
                    }
                }.padding(.top, 8)
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
        panel { VStack(alignment: .leading, spacing: 10) {
            HStack { Label("Child profile", systemImage: "person.crop.circle"); Spacer(); Button("Edit") { showProfile = true }.buttonStyle(.bordered) }
            Text("\(displayName)\(ageText.isEmpty ? "" : " · \(ageText)")").font(.headline)
            Text("Stored on this iPhone by default.").font(.caption).foregroundStyle(muted)
        } }
        panel {
            Button { showFamily = true } label: { Label("Family sharing", systemImage: "person.2.fill") }
            Text("Watch live readings on another iPhone — at home, Nan’s, or when you’re out.")
                .font(.caption)
                .foregroundStyle(muted)
        }.sheet(isPresented: $showFamily) {
            NavigationStack {
                FamilySharingView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showFamily = false }
                        }
                    }
            }
        }
        panel { DisclosureGroup("Second iPhone on this Wi‑Fi") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Share from this iPhone", isOn: Binding(get: { wifi.hosting }, set: { wifi.setHosting($0) })).tint(switchOn)
                if wifi.hosting {
                    Text(wifi.pin).font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                    Button("Copy code") { UIPasteboard.general.string = wifi.pin }
                }
                TextField("Downstairs code", text: Binding(get: { wifi.joinPin }, set: { wifi.setJoinPin($0) }))
                    .keyboardType(.numberPad)
                    .font(.title3.monospacedDigit())
                Toggle("Follow the phone next to the band", isOn: Binding(get: { wifi.following }, set: { wifi.setFollowing($0) })).tint(switchOn)
                Toggle("Play those alerts here", isOn: $wifi.playAlerts).tint(switchOn)
                Text(wifi.status).font(.caption).foregroundStyle(muted)
                Text("Same house only — 4-digit PIN on this Wi‑Fi. Nan in another house uses Family sharing above, not this.")
                    .font(.caption).foregroundStyle(muted)
            }.padding(.top, 8)
        } }
        panel { VStack(alignment: .leading, spacing: 12) {
            Text("Heart-rate alerts").font(.headline)
            if wifi.following {
                Text("You are following the phone next to the band. Change Low / High limits on that phone, not here.")
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
                Toggle("Enable alarms for mapped readings", isOn: $monitor.experimentalCustomAlarms).tint(switchOn)
            }
            Toggle("High limit alarm", isOn: $monitor.alarmSettings.highEnabled).tint(switchOn)
                .onChange(of: monitor.alarmSettings.highEnabled) { enabled in if enabled { monitor.requestNotificationPermission() } }
            HStack {
                Text("High limit (bpm)")
                TextField("Enter limit", value: $monitor.alarmSettings.highThreshold, format: .number)
                    .keyboardType(.numberPad).multilineTextAlignment(.trailing).focused($editingLimit)
            }
            Toggle("Low limit alarm", isOn: $monitor.alarmSettings.lowEnabled).tint(switchOn)
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
        panel { VStack(alignment: .leading, spacing: 12) {
            Text("Skin temperature").font(.headline)
            Toggle("Show Fahrenheit", isOn: $skinFahrenheit).tint(switchOn)
            Text("The band reading stays a wrist temperature. 32.1°C is about 89.8°F. Green, amber and red use the same limits either way.")
                .font(.caption).foregroundStyle(muted)
        } }
        panel { VStack(alignment: .leading, spacing: 12) {
            Text("Sounds and notifications").font(.headline)
            Text("Siren plays in the app even on Silent. Lock-screen banners can still be quiet in Silent or Focus. Allow Time Sensitive for Nivvi.")
                .font(.caption).foregroundStyle(muted)
            Picker("Alert siren", selection: $monitor.selectedSiren) {
                ForEach(NivviSiren.allCases) { Text($0.title).tag($0) }
            }
            Picker("Recovery chime", selection: $monitor.selectedRelief) {
                ForEach(NivviRelief.allCases) { Text($0.title).tag($0) }
            }
            Button(monitor.testingSiren ? "Stop test siren" : "Test siren for 5 seconds") { monitor.testSiren() }
                .buttonStyle(.borderedProminent).tint(coral).disabled(monitor.criticalAlertActive)
            Button("Preview recovery chime") { monitor.testRecoverySound() }
                .buttonStyle(.bordered).disabled(monitor.criticalAlertActive)
            Button("Test notification in 10 seconds") { monitor.testNotification() }.buttonStyle(.bordered)
            Text(monitor.soundStatus).font(.caption)
            Text(monitor.notificationStatus).font(.caption)
            DisclosureGroup("How alerts work") {
                Text("Low alarms fire strictly below the low limit; high alarms fire strictly above the high limit after the dwell time you set. The alarm self-clears after a fresh in-range reading. The looping siren plays as media audio so the Silent switch does not mute it while Nivvi can play sound. Lock-screen notification sounds still follow Silent and Focus — Apple does not let this app override those without Critical Alerts (not granted). Turn media volume up. In iPhone Settings → Notifications → Nivvi, allow Time Sensitive.")
                    .font(.caption).foregroundStyle(muted).padding(.top, 8)
            }
        } }
        Group {
        panel { DisclosureGroup("FAQ") { VStack(alignment: .leading, spacing: 12) {
            DisclosureGroup("How do I share with family?") {
                Text("Settings → Family sharing. Sign in with your own email. The phone next to the band taps Create family code and sends the 6 letters. Everyone else types that same code and chooses who they are. Whoever is with the wearer taps I’m with [name]. Same code when someone else takes over. Same-house Wi‑Fi PIN is only for downstairs.")
                    .font(.caption).padding(.top, 6)
            }
            DisclosureGroup("Which devices work?") {
                Text("Any Bluetooth heart-rate band that uses the standard Heart Rate Service (180D), plus some pulse oximeters (1822) and original Neebo bands. Polar H10, Coospo, Magene and generic 180D straps usually work. Apple Watch, Fitbit Air, Owlet and similar app-locked wearables usually will not appear.")
                    .font(.caption).padding(.top, 6)
            }
            DisclosureGroup("Why connected but waiting?") {
                Text("Bluetooth is linked, but no valid heart-rate packet has arrived yet. Check the band is on the skin, charged, and not connected to another app. A battery number is not a heart-rate reading.")
                    .font(.caption).padding(.top, 6)
            }
            DisclosureGroup("Where is History?") {
                Text("History keeps about one reading every 30 seconds for 30 calendar days on this iPhone. Change the date at the top, or use the arrows. Charts and the list always follow that calendar day — the chart opens on the full day.")
                    .font(.caption).padding(.top, 6)
            }
            DisclosureGroup("Will alarms always sound?") {
                Text("The siren can play in the open app even on Silent. Lock-screen banners can still be quiet in Silent, Focus or Sleep. This is not a medical monitor and not a substitute for being with someone.")
                    .font(.caption).padding(.top, 6)
            }
        }.padding(.top, 12) } }
        panel { DisclosureGroup("Privacy") { VStack(alignment: .leading, spacing: 12) {
            Text("Local use needs no account. Readings, notes and the profile stay on this iPhone for 30 days. Family sharing is optional: a verified email, a 6-letter family code, and the latest live numbers — including band battery — on the Nivvi server in London (family.nivvi.app). Birth dates, avatars and notes are not uploaded. No ads or analytics.")
                .font(.caption)
            Text("Anyone with the family code can join that family. Stop sharing with everyone ends the code. Delete account removes the online login, not this phone’s history. Full notice: nivvi.app/privacy")
                .font(.caption).foregroundStyle(muted)
        }.padding(.top, 12) } }
        panel { DisclosureGroup("Terms") { VStack(alignment: .leading, spacing: 12) {
            Text("Nivvi is a TestFlight family test from Michael Waters, trading as Nivvi, United Kingdom. It shows Bluetooth heart-rate readings for babies, children, teens and adults. It does not diagnose, treat, or replace being with someone or emergency care.")
                .font(.caption)
            Text("Bluetooth, Wi‑Fi, 4G and notifications can fail. You are responsible for how you use the app. English law of England and Wales. Support: hello.nivvi@outlook.com. Full terms: nivvi.app/terms")
                .font(.caption).foregroundStyle(muted)
        }.padding(.top, 12) } }
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

    private var bottomBar: some View { HStack { nav("heart.fill", "Live", 0); nav("chart.xyaxis.line", "History", 1); nav("bell.fill", "Alerts", 2); nav("wave.3.right", "Device", 3) }.padding(8).background(mode == .night ? cardFill : Color.white.opacity(0.94)).clipShape(Capsule()).shadow(color: mode == .night ? .clear : Color(red: 0.09, green: 0.17, blue: 0.26).opacity(0.10), radius: 8, y: 2).padding(.horizontal, 18).padding(.bottom, 10) }
    private func nav(_ icon: String, _ title: String, _ index: Int) -> some View { Button { withAnimation(.easeInOut(duration: 0.2)) { tab = index } } label: { VStack(spacing: 4) { Image(systemName: icon); Text(title).font(.caption.weight(.semibold)) }.foregroundStyle(tab == index ? ink : muted).frame(maxWidth: .infinity).padding(.vertical, 8).background(tab == index ? navSelected : .clear).clipShape(Capsule()) } }
    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(ink)
            .background(cardFill)
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(cardStroke, lineWidth: 1))
            .shadow(color: mode == .night ? .clear : Color(red: 0.09, green: 0.17, blue: 0.26).opacity(0.08), radius: 8, y: 3)
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
        guard let date else { return mirroringNursery ? "Waiting for the monitoring phone" : "No reading received" }
        let seconds = Int(now.timeIntervalSince(date))
        if mirroringNursery {
            guard seconds >= 0 else { return "Updated just now" }
            return "Updated \(seconds)s ago"
        }
        if monitor.staleHeartRateDetected { return "Stale · not a live value" }
        guard connected, seconds >= 0, seconds <= 30 else { return "No fresh reading" }
        return "Updated \(seconds)s ago"
    }
    private var readinessPanel: some View {
        panel {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let summary = readinessSummary(at: context.date)
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 10) {
                        readinessRow("Bluetooth", monitor.bluetoothReady ? "On" : "Unavailable", monitor.bluetoothReady)
                        readinessRow("Device", connected ? "Connected" : "Not connected", connected)
                        Text("Background: " + monitor.backgroundDeliverySummary).font(.caption.bold())
                        if let time = monitor.lastBackgroundSave {
                            Text("Last background history save: \(time.formatted(date: .omitted, time: .standard))").font(.caption)
                        }
                        Text("Leave Nivvi in the app switcher (lock the phone or use another app). Swiping Nivvi away stops background monitoring until you open it again.").font(.caption)
                        let fresh = connected && heartRateDisplay != "No reading" && !monitor.staleHeartRateDetected &&
                            monitor.lastHeartRateUpdate.map { (0...30).contains(context.date.timeIntervalSince($0)) } == true
                        readinessRow("Heart rate", fresh ? "Fresh data arriving" : "Check readings", fresh)
                        readinessRow("Notifications", monitor.notificationSoundAllowed ? "Sound permitted" : "Check permission", monitor.notificationSoundAllowed)
                        let alarmsEnabled = (monitor.alarmSettings.highEnabled || monitor.alarmSettings.lowEnabled) &&
                            (monitor.profile.hasStandardHeartRate || monitor.profile.hasPulseOximeter || (monitor.profile == .custom && monitor.experimentalCustomAlarms))
                        readinessRow("Rate alerts", alarmsEnabled ? "Configured" : "Off or unavailable", alarmsEnabled)
                        Text("The in-app siren ignores the Silent switch. Lock-screen banners can still be quiet. Enable Time Sensitive for Nivvi. Critical Alerts are not in this build.").font(.caption)
                        Button("Guided alarm check") { showReadinessTest = true }.buttonStyle(.bordered)
                        Text("History saves every 30 seconds while data arrives. Alarms check incoming usable readings.").font(.caption)
                    }.padding(.top, 8)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Monitoring readiness").font(.headline)
                        Text(summary.text)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(summary.ready ? accentMint : coral)
                    }
                }
            }
        }
        .sheet(isPresented: $showReadinessTest) { AlarmReadinessView(monitor: monitor) }
    }
    private func readinessSummary(at now: Date) -> (text: String, ready: Bool) {
        if !monitor.bluetoothReady { return ("Check Bluetooth", false) }
        if !connected { return ("Check connection", false) }
        if !monitor.notificationSoundAllowed { return ("Check notification settings", false) }
        let alarmsEnabled = (monitor.alarmSettings.highEnabled || monitor.alarmSettings.lowEnabled) &&
            (monitor.profile.hasStandardHeartRate || monitor.profile.hasPulseOximeter || (monitor.profile == .custom && monitor.experimentalCustomAlarms))
        if !alarmsEnabled { return ("Alerts off", false) }
        let fresh = heartRateDisplay != "No reading" && !monitor.staleHeartRateDetected &&
            monitor.lastHeartRateUpdate.map { (0...30).contains(now.timeIntervalSince($0)) } == true
        if !fresh { return ("Check readings", false) }
        return ("Alerts ready", true)
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
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || beatsPerMinute == nil)) { context in
            let bpm = max(40, min(220, beatsPerMinute ?? 80))
            let period = 60 / bpm
            let wave = beatsPerMinute == nil || reduceMotion ? 0 : (sin(context.date.timeIntervalSinceReferenceDate * 2 * .pi / period) + 1) / 2
            Image(systemName: "heart.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(tint)
                .scaleEffect(1 + 0.18 * wave)
                .opacity(0.82 + 0.18 * wave)
                .accessibilityHidden(true)
        }
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
