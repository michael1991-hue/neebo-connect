import SwiftUI
import CoreBluetooth
import AudioToolbox
import AVFoundation
import UserNotifications
import Charts
import PhotosUI
import ImageIO

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
        case "180F": return characteristic == "2A19"
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
    @Published var showAllDevices = true
    @Published var deviceNames: [UUID: String] = [:]
    @Published var deviceServices: [UUID: [String]] = [:]
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
        p.readValue(for: pendingRead!)
    }
    private func owns(_ p: CBPeripheral) -> Bool { p === peripheral && session.shouldReconnect(p.identifier) && p.state == .connected && connection != .stopping }
    private func addDevice(_ p: CBPeripheral, name: String) {
        deviceNames[p.identifier] = name.isEmpty ? (p.name ?? "Unnamed Bluetooth device") : name
        if !devices.contains(where: { $0.identifier == p.identifier }) { devices.append(p) }
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
    var criticalAlertActive: Bool { alarmActive || staleHeartRateDetected }
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
            try eventArchive.clear(); events = []; eventDays = []; eventError = nil; sampling.reset()
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
        }
        verifiedHeartRate = nil; customHeartRateCandidate = nil; alarmEngine.interrupt()
        pulseOximeterRate = nil
        if connection.isConnected { connection = .waiting }
        status = "No fresh heart-rate reading. Bluetooth may still be connected."
        measurementStatus = reason
    }
    private func receiveHeartRate(at time: Date) {
        lastHeartRateUpdate = time
        if let interval = heartRateFreshness.receive(at: time) {
            sampling.reset()
            recordEvent(kind: "measurement", title: "Heart-rate readings resumed", detail: "Usable heart-rate data received again. \(Int(interval)) seconds between usable readings; this does not identify the cause of the gap.")
        }
        connection = .receiving
        status = "Receiving fresh heart-rate readings."
    }
    private func expireMeasurements() {
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
        if let data = UserDefaults.standard.data(forKey: "nivvi.alarms"), let saved = try? JSONDecoder().decode(AlarmSettings.self, from: data) { alarmSettings = saved; experimentalCustomAlarms = saved.experimentalCustomEnabled }
        session.deviceID = UserDefaults.standard.string(forKey: "nivvi.session.device").flatMap(UUID.init(uuidString:))
        session.enabled = UserDefaults.standard.bool(forKey: "nivvi.session.enabled")
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
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] _, _ in self?.refreshNotificationStatus() }
    }
    func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                self?.notificationSoundAllowed = settings.authorizationStatus == .authorized && settings.soundSetting == .enabled
                self?.notificationStatus = settings.authorizationStatus == .authorized && settings.soundSetting == .enabled ? "Notifications and sounds allowed. Silent mode, Focus and volume settings still apply." : "Notification sound is not fully enabled. Check iPhone Settings → Notifications → Nivvi."
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
        content.interruptionLevel = .timeSensitive
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
        let alertBody = body ?? "\(alarmDetail) Check \(displayNameForAlert) and follow the care plan."
        notify(title: title ?? attentionTitle, body: alertBody, identifier: "nivvi-rate-alarm")
        // iOS does not permit an app to hold an audio session open indefinitely
        // after backgrounding. Repeating time-sensitive reminders keep notifying
        // the caregiver until acknowledgement or a fresh in-range reading.
        notify(title: title ?? attentionTitle, body: "This critical alert is still active. Open Nivvi to acknowledge it.", identifier: "nivvi-rate-alarm-reminder", repeatInterval: 60)
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
    private func playReliefSound() {
        guard foreground else { return }
        do {
            guard let url = Bundle.main.url(forResource: "NivviRelief", withExtension: "wav") else { throw CocoaError(.fileNoSuchFile) }
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playback, mode: .default, options: [.duckOthers])
            try audio.setActive(true)
            siren = try AVAudioPlayer(contentsOf: url); siren?.numberOfLoops = 0; siren?.volume = 0.5
            _ = siren?.play()
            soundStatus = "Playing the gentle recovery chime."
        } catch { soundStatus = "Relief sound could not play: \(error.localizedDescription)" }
    }
    private func startSiren(loop: Bool) {
        guard foreground else { return }
        do {
            guard let url = Bundle.main.url(forResource: "NivviSiren", withExtension: "wav") else { throw CocoaError(.fileNoSuchFile) }
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playback, mode: .default, options: [.duckOthers])
            try audio.setActive(true)
            siren = try AVAudioPlayer(contentsOf: url); siren?.numberOfLoops = loop ? -1 : 0; siren?.volume = 1
            guard siren?.play() == true else { throw CocoaError(.fileReadUnknown) }
            soundStatus = "Siren playing at the iPhone’s current media volume."
        } catch { soundStatus = "Siren could not play: \(error.localizedDescription)" }
    }
    private func stopSiren() {
        soundTestTimer?.invalidate(); soundTestTimer = nil; testingSiren = false
        siren?.stop(); siren = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
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
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] allowed, _ in
            guard allowed else { self?.refreshNotificationStatus(); return }
            DispatchQueue.main.async {
                self?.notify(title: "Nivvi sound test", body: "TEST ONLY — no device reading triggered this sound.", identifier: "nivvi-sound-test", delay: 10)
                self?.soundStatus = "Test notification scheduled in 10 seconds. Lock the phone now to test it."
            }
        }
    }
    func applicationActive(_ isActive: Bool) {
        foreground = isActive
        if isActive {
            expireMeasurements(); refreshNotificationStatus()
            if criticalAlertActive && !alarmAcknowledged { startSiren(loop: true) }
            if let c = measurementCharacteristic { enqueueRead(c) }
            if !active && session.enabled && manager.state == .poweredOn { resumeSession() }
        } else {
            if criticalAlertActive, !alarmAcknowledged {
                notify(title: attentionTitle, body: "An alarm is still active. Open Nivvi to acknowledge it.", identifier: "nivvi-rate-alarm")
            }
            stopSiren()
            // Notification delivery is owned by iOS; do not fake background audio to stay awake.
            if isScanning { scanToken = UUID(); scanDeadline?.invalidate(); manager.stopScan(); connection = .idle }
        }
    }
    private func saveSession() {
        UserDefaults.standard.set(session.enabled, forKey: "nivvi.session.enabled")
        UserDefaults.standard.set(session.deviceID?.uuidString, forKey: "nivvi.session.device")
    }
    private func resetTransport() {
        pollTimer?.invalidate(); noDataTimer?.invalidate(); retryTimer?.invalidate()
        readQueue = []; pendingRead = nil; measurementCharacteristic = nil
        clearLiveValues(); battery = "—"; lastSample = nil
    }
    private func resumeSession() {
        guard session.enabled, let id = session.deviceID, manager.state == .poweredOn else { return }
        if peripheral == nil { peripheral = manager.retrievePeripherals(withIdentifiers: [id]).first }
        guard let p = peripheral else {
            connection = .reconnecting; status = "Looking for your saved wearable…"
            manager.scanForPeripherals(withServices: BluetoothPolicy.measurementServices.map { CBUUID(string: $0) })
            return
        }
        p.delegate = self
        if p.state == .connected {
            connection = .discovering; p.discoverServices(nil)
        } else {
            connection = .reconnecting; status = "Reconnecting automatically. Keep the wearable nearby, or tap Disconnect to stop."
            if p.state == .disconnected { manager.connect(p, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true]) }
        }
    }
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        for p in restored {
            if session.shouldReconnect(p.identifier) { peripheral = p; p.delegate = self; connection = .reconnecting }
            else { central.cancelPeripheralConnection(p) }
        }
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
        devices = []; deviceNames = [:]; deviceServices = [:]; diagnostics = []
        connection = .scanning
        status = "Scanning for nearby wearables for 15 seconds…"
        // A BLE device held by another app on this iPhone may not advertise again.
        let connected = manager.retrieveConnectedPeripherals(withServices: BluetoothPolicy.measurementServices.map { CBUUID(string: $0) })
        for p in connected {
            addDevice(p, name: p.name ?? "Bluetooth device already connected to iPhone")
        }
        manager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        scanDeadline = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            guard let self = self, self.scanToken == token, self.connection == .scanning else { return }
            self.manager.stopScan(); self.connection = .idle
            self.status = self.devices.isEmpty ? "No wearable found. Disconnect other Bluetooth apps, keep the wearable close, then scan again. Try Show other nearby devices if its name differs." : "Tap a device below to connect."
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
            central.stopScan(); peripheral = p; p.delegate = self
            central.connect(p, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true]); return
        }
        guard connection == .scanning else { return }
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? ""
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []).map { $0.uuidString }
        deviceServices[p.identifier] = services
        if showAllDevices || BluetoothPolicy.isCandidate(names: [advertisedName, p.name ?? ""], services: services) {
            addDevice(p, name: advertisedName.isEmpty ? (p.name ?? "") : advertisedName)
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
        recordEvent(kind: "connection", title: "Session started", detail: "Connecting to the selected wearable.")
        peripheral = p; p.delegate = self; connection = .connecting
        status = "Connecting to \(deviceNames[p.identifier] ?? p.name ?? "wearable")…"
        note("Connection requested; waiting for Bluetooth confirmation.")
        manager.connect(p, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
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
        resetTransport(); retrySeconds = 2; connection = .discovering; p.delegate = self
        status = "Connected. Discovering battery and measurement services…"
        note("Bluetooth connection established. Continuous session enabled.")
        recordEvent(kind: "connection", title: "Wearable connected", detail: "Continuous Bluetooth session active. Awaiting fresh measurements.")
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
        // Avoid a tight retry loop on an immediate platform error. A pending BLE request itself has no timeout.
        retryTimer = Timer.scheduledTimer(withTimeInterval: retrySeconds, repeats: false) { [weak self] _ in self?.resumeSession() }
        retrySeconds = min(60, retrySeconds * 2)
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
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard owns(p) else { return }
        if let error = error { note("Service discovery failed: \(error.localizedDescription)"); status = "Service discovery failed. Stop and reconnect."; return }
        let services = Set((p.services ?? []).map { BluetoothPolicy.normalized($0.uuid.uuidString) })
        note("Services: \(services.sorted().joined(separator: ", "))")
        if services.contains("180D") && services.contains("1822") { profile = .combined }
        else if services.contains("180D") { profile = .heartRate }
        else if services.contains("1822") { profile = .pulseOximeter }
        else if services.contains("FFE0") { profile = .custom }
        else { profile = .generic }
        if services.isEmpty { status = "Connected, but no services were returned. Stop and reconnect."; return }
        for service in p.services ?? [] { p.discoverCharacteristics(nil, for: service) }
        connection = .waiting
        status = profile == .generic ? "Connected, but no supported heart-rate or oxygen service was found. This device may require a separate integration." : "Connected. Waiting for measurement data…"
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard owns(p) else { return }
        if let error = error { note("Characteristic discovery failed: \(error.localizedDescription)"); return }
        for c in (service.characteristics ?? []).sorted(by: { $0.uuid.uuidString < $1.uuid.uuidString }) {
            let sid = BluetoothPolicy.normalized(service.uuid.uuidString), cid = BluetoothPolicy.normalized(c.uuid.uuidString)
            log(["event": "characteristic", "service": sid, "uuid": cid, "properties": String(c.properties.rawValue)])
            guard BluetoothPolicy.shouldObserve(service: sid, characteristic: cid) else { continue }
            if (profile.hasStandardHeartRate || profile.hasPulseOximeter) && sid == "FFE0" { continue }
            note("Found \(sid)/\(cid): read=\(c.properties.contains(.read)), notify=\(c.properties.contains(.notify))")
            if sid == "FFE0" && cid == BluetoothPolicy.customMeasurementUUID {
                measurementCharacteristic = c
                measurementStatus = "custom measurement found. Requesting measurements…"
                pollTimer?.invalidate()
                pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                    guard let self = self, self.owns(p), self.foreground else { return }
                    if let c = self.measurementCharacteristic { self.enqueueRead(c) }
                }
            }
            enqueueRead(c)
            if c.properties.contains(.notify) || c.properties.contains(.indicate) { p.setNotifyValue(true, for: c) }
        }
    }
    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        guard owns(p) else { return }
        note("\(c.uuid.uuidString) notifications \(c.isNotifying ? "on" : "off")\(error.map { ": " + $0.localizedDescription } ?? "")")
        if c === measurementCharacteristic && error != nil { measurementStatus = "custom measurement notifications failed; trying readable values instead." }
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard owns(p) else { return }
        // Check before accepting this packet: iOS may have suspended the timer.
        expireMeasurements()
        if c === pendingRead { pendingRead = nil }
        defer { readNext() }
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
        if uuid == "2A19", serviceID == "180F", data.count == 1, data[0] <= 100 { battery = "\(data[0])%" }
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
    private func observeStaleHeartRate(_ bpm: Double, source: String) {
        let wasStale = staleHeartRateDetected
        let crossed = staleHeartRate.observe(bpm, at: Date())
        if crossed {
            staleHeartRateDetected = true
            alarmAcknowledged = false
            let value = MetricText.number(bpm)
            recordEvent(kind: "critical", title: attentionTitle, detail: "The wearable repeated \(value) bpm for three minutes of \(source) readings. Check sensor contact, fit and the child; this may be stale device data.", heartRate: Int(bpm.rounded()))
            startSiren(loop: true)
            if !alarmActive {
                scheduleAlarmNotifications(title: attentionTitle, body: "The wearable repeated \(value) bpm for three minutes. Check \(displayNameForAlert), the sensor fit and the care plan.")
            }
        } else if wasStale && !staleHeartRate.isStale {
            staleHeartRateDetected = false
            if !alarmActive {
                alarmAcknowledged = false
                recordEvent(kind: "critical", title: "Fresh heart-rate reading restored", detail: "A changed \(source) value replaced the repeated reading. This does not establish sensor accuracy or a medical all-clear.", heartRate: Int(bpm.rounded()))
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
        recordEvent(kind: "critical", title: "Alarm acknowledged", detail: detail)
        alarmAcknowledged = true
        stopSiren()
        clearAlarmNotifications()
        soundStatus = "Acknowledged. The alarm stays active until a fresh in-range reading."
    }
    func stop() {
        if session.enabled { recordEvent(kind: "connection", title: "Session disconnected", detail: "Disconnected by the user. Automatic reconnection is off.") }
        session.stop(); saveSession()
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
    @State private var photo: Data?
    @State private var photoItem: PhotosPickerItem?
    @State private var photoError: String?
    @State private var photoLoading = false
    @FocusState private var editingName: Bool
    private let save: (String, Date, String, Data?) -> Bool
    private let canCancel: Bool
    private let genders = ["Girl", "Boy", "Other", "Prefer not to say"]

    init(name: String, birthDate: Date, gender: String, photo: Data?, save: @escaping (String, Date, String, Data?) -> Bool) {
        _name = State(initialValue: name)
        _birthDate = State(initialValue: min(birthDate, Date()))
        _gender = State(initialValue: gender)
        _photo = State(initialValue: photo)
        self.save = save
        canCancel = !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Child photo") {
                    HStack(spacing: 20) {
                        if let data = photo, let picture = UIImage(data: data) {
                            Image(uiImage: picture).resizable().scaledToFill().frame(width: 84, height: 84).clipShape(Circle())
                        } else { Image(systemName: "person.crop.circle.fill").font(.system(size: 64)).foregroundStyle(.teal) }
                        VStack(alignment: .leading, spacing: 10) {
                            PhotosPicker(selection: $photoItem, matching: .images) { Text(photo == nil ? "Add photo" : "Change photo") }
                            if photo != nil { Button("Remove photo", role: .destructive) { photo = nil; photoItem = nil } }
                        }
                    }
                    if photoLoading { ProgressView("Loading photo…") }
                    if let error = photoError { Text(error).font(.caption).foregroundStyle(.red) }
                    Text("Only your selected image is used. Saved on this iPhone.").font(.caption)
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
                        if save(name.trimmingCharacters(in: .whitespacesAndNewlines), birthDate, gender, photo) { dismiss() }
                        else { photoError = "The profile photo could not be saved. Please try again." }
                    }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || photoLoading)
                } footer: { Text("Your profile stays on this iPhone.") }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Set up Nivvi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if canCancel { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            }
        }
        .interactiveDismissDisabled(!canCancel)
        .task(id: photoItem) {
            guard let selected = photoItem else { photoLoading = false; return }
            photoLoading = true; photoError = nil
            do {
                guard let data = try await selected.loadTransferable(type: Data.self),
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 512] as CFDictionary),
                      let resized = UIImage(cgImage: thumbnail).jpegData(compressionQuality: 0.85) else { throw CocoaError(.fileReadCorruptFile) }
                try Task.checkCancellation()
                photo = resized; photoLoading = false
            } catch is CancellationError { }
            catch { photoError = "Could not open that photo. Try another image."; photoLoading = false }
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
    @State private var hours = 0
    @State private var windowEnd: Date?
    private var domain: ClosedRange<Date> {
        HistoryChartPolicy.window(day: day, hours: hours, endingAt: windowEnd ?? entries.last?.time ?? day)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
            Text("\(domain.lowerBound.formatted(date: .omitted, time: .shortened)) – \(domain.upperBound.formatted(date: .omitted, time: .shortened))\(hours == 0 ? " · full calendar day" : "")").font(.caption).monospacedDigit()
            Text("Blank intervals have no plotted readings. Tap or drag near a point to inspect its saved value.").font(.caption).foregroundStyle(.white.opacity(0.7))
            if let entry = selected {
                Text("Selected: \(entry.time.formatted(date: .abbreviated, time: .standard)) · HR \(entry.heartRateValue.map(MetricText.number) ?? "—") bpm · O₂ \(entry.oxygenValue.map(MetricText.number) ?? "—")%")
                    .font(.caption.bold()).foregroundStyle(lavender).monospacedDigit()
            }
            Label("Heart rate", systemImage: "heart.fill").foregroundStyle(coral).font(.headline)
            metricChart(.heartRate, tint: coral).frame(height: 180)
            if entries.contains(where: { $0.oxygenValue != nil }) {
                Label("Oxygen", systemImage: "lungs.fill").foregroundStyle(teal).font(.headline)
                metricChart(.oxygen, tint: teal).frame(height: 130)
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
        return Chart {
            ForEach(points) { point in
                LineMark(x: .value("Time", point.entry.time), y: .value("Value", point.value), series: .value("Continuous segment", point.series))
                    .foregroundStyle(tint)
                PointMark(x: .value("Time", point.entry.time), y: .value("Value", point.value))
                    .symbolSize(5).foregroundStyle(tint)
            }
            if let entry = selected, let value = metric.value(entry), domain.contains(entry.time) {
                RuleMark(x: .value("Selected time", entry.time)).foregroundStyle(lavender.opacity(0.6))
                PointMark(x: .value("Selected time", entry.time), y: .value("Selected value", value)).foregroundStyle(lavender).symbolSize(45)
            }
        }
        .chartXScale(domain: domain)
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
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("nivvi.profile.name") private var childName = ""
    @AppStorage("nivvi.profile.birthDate") private var childBirthDate = 0.0
    @AppStorage("nivvi.profile.gender") private var childGender = "Prefer not to say"
    @AppStorage("nivvi.favorite.device.ids") private var favoriteDeviceIDs = ""
    @State private var showProfile = false
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
    @State private var profilePhoto: Data?
    private var photoURL: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("child-profile.jpg") }
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
        let value = monitor.verifiedHeartRate.map(Double.init) ?? monitor.pulseOximeterRate ?? monitor.customHeartRateCandidate.map(Double.init)
        return value.map { "\(MetricText.number($0)) bpm" } ?? "No reading"
    }
    private var oxygenDisplay: String {
        let value = monitor.pulseOximeterOxygen ?? monitor.customOxygenCandidate.map(Double.init)
        return value.map { "\(MetricText.number($0))%" } ?? "No reading"
    }
    private var liveMeasurementNote: String {
        if monitor.staleHeartRateDetected { return "Repeated value · check sensor" }
        if monitor.verifiedHeartRate != nil || monitor.pulseOximeterRate != nil || monitor.pulseOximeterOxygen != nil { return "Standard Bluetooth value" }
        if monitor.customHeartRateCandidate != nil || monitor.customOxygenCandidate != nil { return "Bluetooth value received" }
        return monitor.profile == .heartRate ? "Waiting for heart-rate data" : "Waiting for device data"
    }
    private var displayName: String { childName.isEmpty ? "Your child" : childName }
    private var birthDate: Date { childBirthDate == 0 ? Date() : Date(timeIntervalSince1970: childBirthDate) }
    private var ageText: String {
        guard childBirthDate > 0 else { return "" }
        let components = Calendar.current.dateComponents([.year, .month], from: birthDate, to: Date())
        let years = components.year ?? 0; let months = components.month ?? 0
        return years > 0 ? "\(years)y \(months)m" : "\(months)m"
    }

    var body: some View {
        ZStack {
            mode.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                if monitor.criticalAlertActive { alarmBanner.padding(.horizontal, 20) }
                ScrollView(showsIndicators: false) {
                    Group {
                        if tab == 0 { home } else if tab == 1 { history } else if tab == 2 { device } else { settings }
                    }.padding(.horizontal, 20).padding(.bottom, 110)
                }
                bottomBar
            }
        }
        .preferredColorScheme(.dark)
        .sheet(item: $captureRequest) { request in
            VStack(alignment: .leading, spacing: 24) {
                Text("Connect to \(request.peripheral.name ?? "wearable")").font(.title2.bold())
                Text("Nivvi will stay connected and try to reconnect after signal loss until you tap Disconnect. Connecting may interrupt another app using the same device. Standard heart-rate and pulse-oximeter formats are supported. A device may expose only spot-checks or require a separate integration. Mapped readings should be checked against your care plan before using them for alarms.")
                Button("Connect wearable") {
                    monitor.connect(request.peripheral)
                    captureRequest = nil
                    tab = 2
                }.buttonStyle(.borderedProminent).controlSize(.large)
                Button("Cancel") { captureRequest = nil }
            }.padding(24).presentationDetents([.medium])
        }
        .onAppear { profilePhoto = try? Data(contentsOf: photoURL); if childName.isEmpty { showProfile = true } }
        .sheet(isPresented: $showProfile) {
            ProfileSetupView(name: childName, birthDate: birthDate, gender: childGender, photo: profilePhoto) { name, date, gender, photo in
                do {
                    if let photo = photo { try photo.write(to: photoURL, options: .atomic) }
                    else if FileManager.default.fileExists(atPath: photoURL.path) { try FileManager.default.removeItem(at: photoURL) }
                    childName = name; childBirthDate = date.timeIntervalSince1970; childGender = gender; profilePhoto = photo
                    return true
                } catch { return false }
            }
        }
        .sheet(isPresented: $showParentNote) {
            NavigationStack {
                Form {
                    Section("What happened?") { TextEditor(text: $parentNote).frame(minHeight: 130) }
                    Text("A timestamp is added when you save. Notes stay on this iPhone.").font(.caption)
                    if let error = monitor.eventError { Text(error).foregroundStyle(.red) }
                }
                .navigationTitle("Add an event note")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showParentNote = false } }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") {
                        monitor.addParentNote(parentNote)
                        if monitor.eventError == nil { parentNote = ""; showParentNote = false; monitor.selectHistoryDay(Date()); historySection = 0 }
                    }.disabled(parentNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                }
            }
        }
        .onChange(of: monitor.selectedHistoryDay) { _ in selectedHistoryReading = nil }
        .onChange(of: monitor.history.count) { count in if count == 0 { selectedHistoryReading = nil } }
        .onChange(of: scenePhase) { phase in monitor.applicationActive(phase == .active) }
        .onAppear { monitor.applicationActive(scenePhase == .active) }
        .onReceive(NotificationCenter.default.publisher(for: .nivviShowLiveHeartRate)) { _ in tab = 0 }
        .scrollDismissesKeyboard(.interactively)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                if let data = profilePhoto, let photo = UIImage(data: data) {
                    Image(uiImage: photo).resizable().scaledToFill().frame(width: 52, height: 52).clipShape(Circle()).accessibilityLabel("Child profile photo")
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(Calendar.current.component(.hour, from: Date()) >= 12 && mode == .day ? "Hello," : mode.greeting).font(.subheadline).foregroundStyle(.white.opacity(0.72))
                    Text(displayName).font(.system(size: 34, weight: .bold, design: .rounded))
                }
                Spacer()
                Button { manualMode = manualMode == nil ? (mode == .night ? .day : .night) : nil } label: {
                    Image(systemName: mode.symbol).font(.title3).foregroundStyle(mode == .night ? lavender : .yellow)
                        .frame(width: 48, height: 48).background(.white.opacity(0.12)).clipShape(Circle())
                }
            }
            HStack(spacing: 10) {
                Circle().fill(monitor.connection == .receiving ? teal : (connected ? .orange : .gray)).frame(width: 11, height: 11)
                Text(monitor.connection.label).font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(mode.rawValue) mode").font(.caption.weight(.bold)).padding(.horizontal, 11).padding(.vertical, 6)
                    .background(.white.opacity(0.12)).clipShape(Capsule())
            }
            if !ageText.isEmpty { Text(childGender == "Prefer not to say" ? ageText : "\(ageText) · \(childGender)").font(.caption).foregroundStyle(.white.opacity(0.6)) }
        }.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 18)
    }

    private var alarmBanner: some View {
                HStack(spacing: 12) {
                    Image(systemName: "bell.and.waves.fill").foregroundStyle(.white)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(displayName) needs your attention").font(.headline)
                        Text(monitor.staleHeartRateDetected ? (monitor.alarmAcknowledged ? "Acknowledged · repeated reading still needs checking." : "Repeated heart-rate value detected. Check sensor contact and your child.") : (monitor.alarmAcknowledged ? "Acknowledged · waiting for a fresh in-range reading." : "Check your child and follow their care plan.")).font(.caption)
                    }
                    Spacer()
                    if !monitor.alarmAcknowledged {
                        Button("Acknowledge") { monitor.silenceAlarm() }.buttonStyle(.bordered).tint(.white)
                    }
                }.padding(16).background(coral).clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private var home: some View {
        VStack(alignment: .leading, spacing: 18) {
            readinessPanel
            Text("CURRENT STATUS").font(.caption.weight(.bold)).tracking(1.2).foregroundStyle(.white.opacity(0.55))
            HStack(alignment: .firstTextBaseline) { Text(monitor.connection == .receiving ? "Fresh heart-rate data" : (connected ? "Waiting for heart rate" : "Ready to connect")).font(.title2.bold()); Spacer(); Image(systemName: mode.symbol).foregroundStyle(mode == .night ? lavender : .yellow) }
            HStack(spacing: 14) {
                readingCard("Heart rate", heartRateDisplay, heartRateDisplay == "No reading" ? "Waiting for usable heart rate" : liveMeasurementNote, "heart.fill", coral, receivedAt: monitor.lastHeartRateUpdate, animate: !monitor.staleHeartRateDetected)
                if monitor.profile == .custom || monitor.profile.hasPulseOximeter { readingCard("Oxygen", oxygenDisplay, oxygenDisplay == "No reading" ? "Waiting for usable oxygen data" : liveMeasurementNote, "lungs.fill", teal, receivedAt: monitor.lastOxygenUpdate) }
            }
            if let spot = monitor.spotCheckText, let time = monitor.spotCheckReceived {
                panel { VStack(alignment: .leading, spacing: 8) {
                    Label("Last spot-check", systemImage: "checkmark.circle").font(.headline)
                    Text("Received \(time.formatted(date: .abbreviated, time: .standard))").font(.caption.bold()).foregroundStyle(lavender)
                    Text(spot).font(.subheadline)
                    Text("One-off result · not live monitoring · no live alarms").font(.caption).foregroundStyle(.white.opacity(0.7))
                } }
            }

            Button { monitor.selectHistoryDay(Date()); tab = 1 } label: {
                HStack { Text("View today’s story").font(.headline); Spacer(); Image(systemName: "arrow.right") }
                    .foregroundStyle(Color(red: 0.06, green: 0.16, blue: 0.25)).padding(18).frame(maxWidth: .infinity)
                    .background(lavender).clipShape(RoundedRectangle(cornerRadius: 20))
            }
            supportiveCard
            if !monitor.status.isEmpty { Text(monitor.status).font(.caption).foregroundStyle(.white.opacity(0.6)).fixedSize(horizontal: false, vertical: true) }
        }
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
            Text("General guidance only · not medical advice").font(.caption2).foregroundStyle(.white.opacity(0.6))
        } }
    }
    private var history: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("History").font(.largeTitle.bold()); Spacer(); Button { showParentNote = true } label: { Label("Add note", systemImage: "plus") }.buttonStyle(.bordered) }
            Text("30 calendar days on this iPhone").foregroundStyle(.white.opacity(0.7))
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
                    panel { VStack(alignment: .leading, spacing: 9) {
                        timestamp(event.time, tint: event.kind == "alarm" || event.kind == "critical" ? coral : lavender)
                        Label(event.title, systemImage: event.kind == "alarm" || event.kind == "critical" ? "bell.fill" : event.kind == "note" ? "note.text" : "antenna.radiowaves.left.and.right").font(.headline)
                        Text(event.detail).font(.subheadline).foregroundStyle(.white.opacity(0.8))
                        if let bpm = event.heartRate { Text("\(bpm) bpm").font(.title3.bold()).foregroundStyle(coral) }
                    } }
                }
                if let error = monitor.eventError { Text(error).foregroundStyle(coral) }
            } else {
                Text("\(monitor.history.count) readings on this day").font(.subheadline)
                Text("New history snapshots are saved every 30 seconds while data arrives. Alarm checks use eligible incoming heart-rate readings, independently of history snapshots. Older imports keep their original timing.").font(.caption).foregroundStyle(.white.opacity(0.7))
                if monitor.history.isEmpty { panel { Text("No saved readings for this day.") } }
                else {
                    panel {
                        HistoryChartsView(entries: monitor.history, day: monitor.selectedHistoryDay, selected: $selectedHistoryReading, coral: coral, teal: teal, lavender: lavender)
                    }
                    Text("Latest 50 readings for this day · export CSV for all entries").font(.caption)
                    ForEach(Array(monitor.history.suffix(50).reversed())) { sample in
                        panel { VStack(alignment: .leading, spacing: 9) {
                            timestamp(sample.time, tint: lavender)
                            HStack { Text(sample.heartRateValue.map { "\(MetricText.number($0)) bpm" } ?? "HR —").foregroundStyle(coral); Spacer(); Text(sample.oxygenValue.map { "O₂ \(MetricText.number($0))%" } ?? "O₂ —").foregroundStyle(teal) }.font(.title3.bold())
                            Text(sample.source == "experimental-custom" ? "Mapped Bluetooth reading" : "Standard Bluetooth reading").font(.caption).foregroundStyle(.white.opacity(0.7))
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
                        Button("Delete all history", role: .destructive) { confirmDeleteHistory = true }
                    }.padding(.top, 10)
                }
                .confirmationDialog("Delete all saved readings, events and notes?", isPresented: $confirmDeleteHistory) {
                    Button("Delete", role: .destructive) { monitor.clearHistory(); historyExport = nil; eventsExport = nil }
                }
            }
        }
    }
    private func timestamp(_ time: Date, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(time.formatted(date: .omitted, time: .standard)).font(.system(size: 24, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(tint)
            Spacer()
            Text(time.formatted(date: .abbreviated, time: .omitted)).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.75))
        }
    }

    private var device: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Device").font(.largeTitle.bold())
            panel { HStack(spacing: 14) { Image(systemName: "wave.3.right.circle.fill").font(.largeTitle).foregroundStyle(teal); VStack(alignment: .leading) { Text("Bluetooth heart-rate device").font(.headline); Text(monitor.connection.label).foregroundStyle(connected ? teal : .white.opacity(0.6)) }; Spacer() } }
            panel { VStack(alignment: .leading, spacing: 6) { Text("PROFILE").font(.caption.bold()).foregroundStyle(.white.opacity(0.55)); Text(monitor.profile.rawValue).font(.headline); Text("Nivvi only displays measurements when the Bluetooth format is recognised.").font(.caption).foregroundStyle(.white.opacity(0.6)) } }
            HStack(spacing: 14) { metric("Battery", monitor.battery == "—" ? "—" : monitor.battery); metric("Mode", mode.rawValue) }
            Button { monitor.active ? monitor.stop() : monitor.scan() } label: { Text(monitor.active ? "Disconnect" : (monitor.isScanning ? "Scanning…" : "Scan for devices")).font(.headline).frame(maxWidth: .infinity).padding(17) }.buttonStyle(.borderedProminent).tint(coral).disabled(monitor.isScanning)
            ForEach(sortedDevices, id: \.identifier) { p in
                HStack(spacing: 10) {
                    Button { captureRequest = CaptureRequest(peripheral: p) } label: {
                        HStack { VStack(alignment: .leading) { Text(monitor.deviceNames[p.identifier] ?? p.name ?? "Unnamed Bluetooth device").font(.headline); Text(BluetoothPolicy.isCandidate(names: [], services: monitor.deviceServices[p.identifier] ?? []) ? "Measurement service advertised · tap to inspect" : "Compatibility checked after connection").font(.caption) }; Spacer(); Image(systemName: "chevron.right") }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                    }.buttonStyle(.bordered).disabled(monitor.active)
                    Button { toggleFavourite(p) } label: { Image(systemName: isFavourite(p) ? "star.fill" : "star").foregroundStyle(isFavourite(p) ? .yellow : .white.opacity(0.7)).padding(12) }.accessibilityLabel(isFavourite(p) ? "Remove favourite device" : "Favourite device")
                }
            }
            Text("Choose your Bluetooth heart-rate device. Star a device to keep it at the top of the list. Supported formats: standard Heart Rate Service and Pulse Oximeter Service. Seeing a Bluetooth device does not mean its measurements are accessible. Mapped formats should be checked independently. Close other Bluetooth apps before connecting.").font(.caption).foregroundStyle(.white.opacity(0.7))
            Toggle("Show other nearby Bluetooth devices", isOn: $monitor.showAllDevices)
                .disabled(monitor.active || monitor.isScanning)
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
                }.font(.caption).foregroundStyle(.white.opacity(0.8))
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
            Text("Stored on this iPhone by default.").font(.caption).foregroundStyle(.white.opacity(0.6))
        } }
        panel { VStack(alignment: .leading, spacing: 12) {
            Text("Heart-rate alerts").font(.headline)
            HStack { Label("Low", systemImage: "arrow.down.heart"); Spacer(); Text(monitor.alarmSettings.lowEnabled ? monitor.alarmSettings.lowThreshold.map { "Below \($0) bpm" } ?? "Set a limit" : "Off") }.foregroundStyle(coral)
            Divider()
            HStack { Text("Within limits"); Spacer(); Text(configuredRangeLabel) }.foregroundStyle(teal)
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
            Text("Low alarms fire strictly below the low limit; high alarms fire strictly above the high limit. The alarm self-clears after a fresh in-range reading. Lock-screen sounds depend on iPhone volume, Silent mode, Focus and notification permissions; Critical Alerts approval is not included.").font(.caption).foregroundStyle(.white.opacity(0.7))
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
                Text("The same received heart-rate value for three minutes triggers a possible repeated-data warning. A gap over 45 seconds restarts the pending duration; missing data is handled separately. Rounded, averaged or cached readings may legitimately repeat: this heuristic is not proof of sensor failure or an SVT detector. Check the sensor and your child and follow the care plan. A changed value clears this warning but does not prove accuracy. Device-specific validation is required.").font(.caption).padding(.top, 6)
            }
            DisclosureGroup("How do alarms work?") {
                Text("Low alarms fire strictly below your configured low limit; high alarms fire strictly above the high limit after the selected dwell time. Acknowledgement silences the siren, while a fresh in-range value self-clears the alert and writes a relief event. Configure limits only from your care plan.").font(.caption).padding(.top, 6)
            }
            DisclosureGroup("How much history is kept?") {
                Text("Readings are sampled into history every 30 seconds while usable data arrives. Alarm checks still use each valid incoming reading. The app keeps 30 calendar days locally and can export CSV files; deletion removes saved readings, events and notes from this app’s storage.").font(.caption).padding(.top, 6)
            }

        }.padding(.top, 12) } }
        panel { DisclosureGroup("Privacy") { VStack(alignment: .leading, spacing: 12) {
            Text("No account is required. Readings, events, notes and the child profile are saved on this iPhone by default. Nivvi does not use analytics, an AI service, or a remote caregiver backend in this build.").font(.caption)
            Text("Sharing is user-initiated through the iOS share sheet. iOS backups and any recipient may create additional copies. Bluetooth, photo and notification permissions can be withdrawn in iPhone Settings.").font(.caption).foregroundStyle(.white.opacity(0.7))

        }.padding(.top, 12) } }
        panel { DisclosureGroup("Terms") { VStack(alignment: .leading, spacing: 12) {
            Text("Nivvi is a record-and-alert companion, not a medical device, diagnosis or emergency service. Bluetooth links, sensors, alarms and notifications can fail or be delayed. Follow your child’s care plan and seek urgent help for serious symptoms; do not wait for this app.").font(.caption)
            Text("Before public release, the operator name, monitored support address, final privacy notice and jurisdiction-specific terms must be completed in the support documentation.").font(.caption).foregroundStyle(.white.opacity(0.7))

        }.padding(.top, 12) } }
        panel { DisclosureGroup("Family sharing") { VStack(alignment: .leading, spacing: 12) {
            Text("Use History → export to share a readings or events CSV with a trusted family member. The current build has no account service or live remote sharing.").font(.caption)
            Text("Member access and invitations will be added only with an authenticated, consent-based service; this build never uploads a child’s readings automatically.").font(.caption).foregroundStyle(.white.opacity(0.7))

        }.padding(.top, 12) } }
        panel { DisclosureGroup("Connection and support") { VStack(alignment: .leading, spacing: 12) {
            Text("Keeps the Bluetooth session active and attempts reconnection after signal loss. Tap Disconnect to end the session.").font(.caption)
            Text("Background readings require device notifications. Keep Nivvi open if the wearable only responds to reads. Force-quitting the app, Bluetooth being off, an empty battery or iOS restrictions can interrupt monitoring.").font(.caption).foregroundStyle(.white.opacity(0.7))

        }.padding(.top, 12) } }
        panel { DisclosureGroup("About Nivvi") { VStack(alignment: .leading, spacing: 12) {
            Text("Nivvi 0.8 · Build 8").font(.headline)
            Text("Bluetooth: \(monitor.connection.label) · Profile: \(monitor.profile.rawValue) · Battery: \(monitor.battery)").font(.caption)
            Text("Readings, events and notes are retained locally for 30 calendar days. The iPhone controls Bluetooth and notifications; Nivvi cannot activate cellular service or update proprietary device firmware.").font(.caption).foregroundStyle(.white.opacity(0.7))

        }.padding(.top, 12) } }
        }
        Text("Nivvi 0.8 · Build 8").font(.caption).foregroundStyle(.secondary)
    } }

    private var bottomBar: some View { HStack { nav("house.fill", "Home", 0); nav("chart.xyaxis.line", "History", 1); nav("wave.3.right", "Device", 2); nav("gearshape.fill", "Settings", 3) }.padding(8).background(.white.opacity(0.1)).clipShape(Capsule()).padding(.horizontal, 18).padding(.bottom, 10) }
    private func nav(_ icon: String, _ title: String, _ index: Int) -> some View { Button { withAnimation(.easeInOut(duration: 0.2)) { tab = index } } label: { VStack(spacing: 4) { Image(systemName: icon); Text(title).font(.caption2) }.foregroundStyle(tab == index ? lavender : .white.opacity(0.65)).frame(maxWidth: .infinity).padding(.vertical, 8).background(tab == index ? .white.opacity(0.12) : .clear).clipShape(Capsule()) } }
    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View { content().padding(18).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.09)).clipShape(RoundedRectangle(cornerRadius: 22)) }
    private func readingCard(_ title: String, _ value: String, _ note: String, _ icon: String, _ tint: Color, receivedAt: Date?, animate: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ReadingUpdateIcon(symbol: icon, tint: tint, receivedAt: receivedAt, enabled: connected && value != "No reading" && animate)
            Text(title).font(.subheadline)
            Text(value).font(.headline)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(readingAge(receivedAt, now: context.date)).font(.caption.bold())
                    .foregroundStyle(tint)
            }
            Text(note).font(.caption2).foregroundStyle(.white.opacity(0.65))
        }.padding(16).frame(maxWidth: .infinity, minHeight: 170, alignment: .leading)
            .background(.white.opacity(0.09)).clipShape(RoundedRectangle(cornerRadius: 22))
    }
    private func readingAge(_ date: Date?, now: Date) -> String {
        guard let date else { return "No reading received" }
        let seconds = Int(now.timeIntervalSince(date))
        guard connected, seconds >= 0, seconds <= 30 else { return "No fresh reading" }
        return "Updated \(seconds)s ago"
    }
    private var readinessPanel: some View {
        panel { DisclosureGroup("Monitoring readiness") {
            VStack(alignment: .leading, spacing: 10) {
                readinessRow("Bluetooth", monitor.bluetoothReady ? "On" : "Unavailable", monitor.bluetoothReady)
                readinessRow("Device", connected ? "Connected" : "Not connected", connected)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let fresh = connected && heartRateDisplay != "No reading" && !monitor.staleHeartRateDetected &&
                        monitor.lastHeartRateUpdate.map { (0...30).contains(context.date.timeIntervalSince($0)) } == true
                    readinessRow("Heart rate", fresh ? "Fresh data arriving" : "Check readings", fresh)
                }
                readinessRow("Notifications", monitor.notificationSoundAllowed ? "Sound permitted" : "Check permission", monitor.notificationSoundAllowed)
                let alarmsEnabled = (monitor.alarmSettings.highEnabled || monitor.alarmSettings.lowEnabled) &&
                    (monitor.profile.hasStandardHeartRate || monitor.profile.hasPulseOximeter || (monitor.profile == .custom && monitor.experimentalCustomAlarms))
                readinessRow("Rate alerts", alarmsEnabled ? "Configured" : "Off or unavailable", alarmsEnabled)
                Text("Permission does not confirm audibility. Volume, Silent mode, Focus and iOS restrictions still apply.").font(.caption)
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
    private func smallCard(_ title: String, _ value: String, _ icon: String, _ tint: Color) -> some View { HStack { Image(systemName: icon).foregroundStyle(tint); VStack(alignment: .leading) { Text(title).font(.subheadline); Text(value).font(.caption).foregroundStyle(.white.opacity(0.6)) } }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.09)).clipShape(RoundedRectangle(cornerRadius: 18)) }
    private func metric(_ title: String, _ value: String) -> some View { VStack(alignment: .leading) { Text(title).font(.caption).foregroundStyle(.white.opacity(0.55)); Text(value).font(.headline) }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.09)).clipShape(RoundedRectangle(cornerRadius: 18)) }
}

extension Notification.Name {
    static let nivviShowLiveHeartRate = Notification.Name("nivvi.showLiveHeartRate")
}

final class NivviAppDelegate: NSObject, UIApplicationDelegate {
    let monitor = Monitor()
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
            Image(systemName: symbol).foregroundStyle(tint)
                .scaleEffect(1 + 0.12 * pulse)
                .accessibilityHidden(true)
        }.frame(height: 28)
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
        "Enable the Silent mode or Focus you normally use. Start the test, lock your phone and check whether you hear it. This app does not have Critical Alerts approval.",
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
