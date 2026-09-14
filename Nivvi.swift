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
    case custom = "Experimental custom format"
    case heartRate = "Standard heart-rate device"
    case generic = "Bluetooth device"
    case unknown = "Profile not identified"
}

struct SavedMeasurement: Codable, Identifiable {
    var id: UUID = UUID()
    let time: Date
    let heartRate: Int?
    let oxygen: Int?
    let source: String
    var continuityID: UUID? = nil
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
    static func normalized(_ value: String) -> String {
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if result.hasPrefix("0000"), result.hasSuffix("-0000-1000-8000-00805F9B34FB") {
            return String(result.dropFirst(4).prefix(4))
        }
        return result
    }
    static func isCandidate(names: [String], services: [String]) -> Bool {
        // Advertised names are not evidence of measurement compatibility.
        services.map(normalized).contains { ["180D", "FFE0"].contains($0) }
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
        return (1...299).contains(bpm) ? bpm : nil
    }
    static func shouldObserve(service: String, characteristic: String) -> Bool {
        let service = normalized(service), characteristic = normalized(characteristic)
        switch service {
        case "FFE0": return [customMeasurementUUID, "FFEA", "FFE4"].contains(characteristic)
        case "180F": return characteristic == "2A19"
        case "180D": return characteristic == "2A37"
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
    @Published var showAllDevices = false
    @Published var deviceNames: [UUID: String] = [:]
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
    @Published var profile: DeviceProfile = .unknown
    // Standard-format decoding is not clinical validation of the sensor.
    @Published var verifiedHeartRate: Int?
    @Published var verifiedOxygen: Int?
    @Published var customHeartRateCandidate: Int?
    @Published var customOxygenCandidate: Int?
    @Published var alarmSettings = AlarmSettings() {
        didSet {
            if let data = try? JSONEncoder().encode(alarmSettings) { UserDefaults.standard.set(data, forKey: "nivvi.alarms") }
            alarmEngine.reset(); alarmKind = nil; stopSiren()
        }
    }
    @Published private(set) var alarmKind: RateAlarm?
    var alarmActive: Bool { alarmKind != nil }
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
    private lazy var eventArchive = EventHistoryStore(folder: folder)
    var recordedDays: [Date] { Array(Set(historyDays + eventDays)).sorted(by: >) }
    var totalEventsToday: Int { events.count }
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
    private func saveMeasurement(heartRate: Int?, oxygen: Int?, source: String) {
        let entry = SavedMeasurement(time: Date(), heartRate: heartRate, oxygen: oxygen, source: source, continuityID: continuityID)
        measurementTime = entry.time
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
        customHeartRateCandidate = nil; customOxygenCandidate = nil
        measurementTime = nil; lastCustomMeasurement = nil
        if resetFreshness { heartRateFreshness.reset(); continuityID = UUID() }
        alarmEngine.interrupt()
    }
    private func pauseHeartRate(_ reason: String) {
        if heartRateFreshness.pause() {
            continuityID = UUID(); sampling.reset()
            recordEvent(kind: "measurement", title: "Heart-rate readings paused", detail: reason)
        }
        verifiedHeartRate = nil; customHeartRateCandidate = nil; alarmEngine.interrupt()
        if connection.isConnected { connection = .waiting }
        status = "No fresh heart-rate reading. Bluetooth may still be connected."
        measurementStatus = reason
    }
    private func receiveHeartRate(at time: Date) {
        if let interval = heartRateFreshness.receive(at: time) {
            sampling.reset()
            recordEvent(kind: "measurement", title: "Heart-rate readings resumed", detail: "Usable heart-rate data received again. \(Int(interval)) seconds between usable readings; this does not identify the cause of the gap.")
        }
        connection = .receiving
        status = "Receiving fresh heart-rate readings."
    }
    private func expireMeasurements() {
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
                self?.notificationStatus = settings.authorizationStatus == .authorized && settings.soundSetting == .enabled ? "Notifications and sounds allowed. Silent mode, Focus and volume settings still apply." : "Notification sound is not fully enabled. Check iPhone Settings → Notifications → Nivvi."
            }
        }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // The foreground alarm already loops its own sound. Tests play the notification sound.
        completionHandler(notification.request.identifier == "nivvi-rate-alarm" && foreground ? [.banner] : [.banner, .sound])
    }
    private func notify(title: String, body: String, identifier: String, delay: TimeInterval? = nil, sirenSound: Bool = true) {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body
        content.sound = sirenSound ? UNNotificationSound(named: UNNotificationSoundName(rawValue: "NivviSiren.wav")) : .default
        content.interruptionLevel = .timeSensitive
        let trigger = delay.map { UNTimeIntervalNotificationTrigger(timeInterval: $0, repeats: false) }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)) { [weak self] error in
            if let error = error { DispatchQueue.main.async { self?.notificationStatus = "Notification failed: \(error.localizedDescription)" } }
        }
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
    func testSiren() {
        guard !alarmActive else { return }
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
            if alarmActive { startSiren(loop: true) }
            if let c = measurementCharacteristic { enqueueRead(c) }
            if !active && session.enabled && manager.state == .poweredOn { resumeSession() }
        } else {
            if let kind = alarmKind, siren != nil {
                notify(title: kind.title, body: "An alarm is still active. Open Nivvi to review or silence it.", identifier: "nivvi-rate-alarm")
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
            manager.scanForPeripherals(withServices: [CBUUID(string: "180D"), CBUUID(string: "FFE0")])
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
        devices = []; deviceNames = [:]; diagnostics = []
        connection = .scanning
        status = "Scanning for nearby wearables for 15 seconds…"
        // A BLE device held by another app on this iPhone may not advertise again.
        let connected = manager.retrieveConnectedPeripherals(withServices: [CBUUID(string: "180D"), CBUUID(string: "FFE0")])
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
        if services.contains("180D") { profile = .heartRate }
        else if services.contains("FFE0") { profile = .custom }
        else { profile = .generic }
        if services.isEmpty { status = "Connected, but no services were returned. Stop and reconnect."; return }
        for service in p.services ?? [] { p.discoverCharacteristics(nil, for: service) }
        connection = .waiting
        status = "Connected. Waiting for measurement data…"
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard owns(p) else { return }
        if let error = error { note("Characteristic discovery failed: \(error.localizedDescription)"); return }
        for c in (service.characteristics ?? []).sorted(by: { $0.uuid.uuidString < $1.uuid.uuidString }) {
            let sid = BluetoothPolicy.normalized(service.uuid.uuidString), cid = BluetoothPolicy.normalized(c.uuid.uuidString)
            log(["event": "characteristic", "service": sid, "uuid": cid, "properties": String(c.properties.rawValue)])
            guard BluetoothPolicy.shouldObserve(service: sid, characteristic: cid) else { continue }
            if profile == .heartRate && sid == "FFE0" { continue }
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
            if candidate.heartRate != nil { receiveHeartRate(at: Date()) }
            else { pauseHeartRate("No usable heart rate in the custom-format packet. Oxygen or other values do not confirm a fresh heart rate.") }
            measurementStatus = candidate.heartRate == nil && candidate.oxygen == nil ? "Custom measurement received (\(data.count) bytes), but the values or frame format are not recognised." : "Experimental custom values received; compare against reference device."
            if candidate.heartRate != nil || candidate.oxygen != nil {
                saveMeasurement(heartRate: candidate.heartRate, oxygen: candidate.oxygen, source: "experimental-custom")
                if let candidateRate = candidate.heartRate { evaluateExperimentalRateAlarm(candidateRate) }
                else { alarmEngine.interrupt() }
            } else { measurementTime = nil; alarmEngine.interrupt() }
        }
        // 2A5E/2A5F are standard pulse-ox measurements. Values stay hidden until
        // a complete standards-compliant parser is added; never infer from raw bytes.
        if let i = readings.firstIndex(where: { $0.id == key }) {
            readings[i].count += 1; readings[i].hex = hex
        } else { readings.append(Reading(id:key, count:1, hex:hex)) }
        if uuid == "2A19", serviceID == "180F", data.count == 1, data[0] <= 100 { battery = "\(data[0])%" }
        if uuid == "FFEA", serviceID == "FFE0", data.count == 2 { counter = "\(Int(data[0]) | (Int(data[1]) << 8)) — possible minutes" }
    }
    private func evaluateExperimentalRateAlarm(_ bpm: Int) {
        let previousAlarm = alarmKind
        let event = alarmEngine.ingest(bpm: bpm, source: "experimental-custom", at: Date(), settings: alarmSettings, allowExperimentalCustom: experimentalCustomAlarms)
        alarmKind = alarmEngine.active
        if let event = event {
            recordEvent(kind: "alarm", title: event.title, detail: "Experimental custom value crossed the configured limit for \(alarmSettings.durationSeconds) seconds. Verify against reference device or your care plan.", heartRate: bpm)
            startSiren(loop: true)
            notify(title: event.title, body: "Experimental custom value \(bpm) crossed your configured limit. Verify the reading and follow your care plan.", identifier: "nivvi-rate-alarm")
            status = event.title + " — verify the custom-format reading and follow your care plan."
        } else if !alarmActive && previousAlarm != nil && !testingSiren {
            recordEvent(kind: "alarm", title: "Reading back within limits", detail: "Experimental custom value returned within the configured limits.", heartRate: bpm)
            stopSiren()
        }
    }

    private func evaluateRateAlarm(_ bpm: Int) {
        let previousAlarm = alarmKind
        let event = alarmEngine.ingest(bpm: bpm, source: "standard-2A37", at: Date(), settings: alarmSettings, allowExperimentalCustom: experimentalCustomAlarms)
        alarmKind = alarmEngine.active
        if let event = event {
            recordEvent(kind: "alarm", title: event.title, detail: "Configured limit persisted for \(alarmSettings.durationSeconds) seconds. Standard Bluetooth heart-rate input.", heartRate: bpm)
            startSiren(loop: true)
            notify(title: event.title, body: "\(bpm) bpm crossed your configured limit. Check your child and follow their care plan.", identifier: "nivvi-rate-alarm")
            status = event.title + " — check your child and follow their care plan."
        } else if !alarmActive {
            if previousAlarm != nil { recordEvent(kind: "alarm", title: "Reading back within limits", detail: "A fresh standard-format reading ended the alert. This is not a medical all-clear.", heartRate: bpm) }
            if !testingSiren { stopSiren() }
        }
    }
    func silenceAlarm() {
        if let kind = alarmKind { recordEvent(kind: "alarm", title: "Alarm silenced", detail: kind.title + " acknowledged by the caregiver.") }
        alarmEngine.silence(); alarmKind = nil; stopSiren()
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["nivvi-rate-alarm"])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["nivvi-rate-alarm"])
        soundStatus = "Silenced. The same excursion stays muted until a new in-range reading or a different limit is reached."
    }
    func stop() {
        if session.enabled { recordEvent(kind: "connection", title: "Session disconnected", detail: "Disconnected by the user. Automatic reconnection is off.") }
        session.stop(); saveSession()
        scanToken = UUID(); scanDeadline?.invalidate(); manager.stopScan()
        resetTransport(); closeCaptureLog(); alarmEngine.reset(); alarmKind = nil; stopSiren()
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
                Text("Selected: \(entry.time.formatted(date: .abbreviated, time: .standard)) · HR \(entry.heartRate.map(String.init) ?? "—") bpm · O₂ \(entry.oxygen.map(String.init) ?? "—")%")
                    .font(.caption.bold()).foregroundStyle(lavender).monospacedDigit()
            }
            Label("Heart rate", systemImage: "heart.fill").foregroundStyle(coral).font(.headline)
            metricChart(.heartRate, tint: coral).frame(height: 180)
            if entries.contains(where: { $0.oxygen != nil }) {
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
    private var heartRateDisplay: String { (monitor.verifiedHeartRate ?? monitor.customHeartRateCandidate).map { "\($0) bpm" } ?? "Not decoded" }
    private var oxygenDisplay: String { (monitor.verifiedOxygen ?? monitor.customOxygenCandidate).map { "\($0)%" } ?? "Not decoded" }
    private var liveMeasurementNote: String {
        if monitor.verifiedHeartRate != nil || monitor.verifiedOxygen != nil { return "Standard Bluetooth value" }
        if monitor.customHeartRateCandidate != nil || monitor.customOxygenCandidate != nil { return "Experimental adapter candidate · verify independently" }
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
                if monitor.alarmActive { alarmBanner.padding(.horizontal, 20) }
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
                Text("Nivvi will stay connected and try to reconnect after signal loss until you tap Disconnect. Connecting may interrupt another app using the same device. Standard heart-rate devices are supported. Custom-format readings remain experimental; their alarms require explicit opt-in in Settings.")
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
                    VStack(alignment: .leading, spacing: 3) { Text(monitor.alarmKind?.title ?? "Heart-rate alert").font(.headline); Text("Check your child and follow their care plan.").font(.caption) }
                    Spacer()
                    Button("Silence") { monitor.silenceAlarm() }.buttonStyle(.bordered).tint(.white)
                }.padding(16).background(coral).clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private var home: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("CURRENT STATUS").font(.caption.weight(.bold)).tracking(1.2).foregroundStyle(.white.opacity(0.55))
            HStack(alignment: .firstTextBaseline) { Text(monitor.connection == .receiving ? "Fresh heart-rate data" : (connected ? "Waiting for heart rate" : "Ready to connect")).font(.title2.bold()); Spacer(); Image(systemName: mode.symbol).foregroundStyle(mode == .night ? lavender : .yellow) }
            HStack(spacing: 14) {
                readingCard("Heart rate", heartRateDisplay, liveMeasurementNote, "heart.fill", coral)
                if monitor.profile == .custom { readingCard("Oxygen", oxygenDisplay, liveMeasurementNote, "lungs.fill", teal) }
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
            Label(monitor.alarmActive ? "One step at a time" : "Here for your little one", systemImage: "heart.text.clipboard").font(.headline)
            Text(monitor.alarmActive ? "Take a breath and stay close to your little one. Check how they are and follow the plan from their care team." : "You can add a note about how your little one is doing. Small observations can help you explain what happened to their care team.").font(.subheadline)
            if monitor.alarmActive {
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
                if historySection == 0 && !eventKinds.isEmpty {
                    Picker("Event type", selection: $eventFilter) { Text("All").tag("All"); ForEach(eventKinds, id: \.self) { Text($0.capitalized).tag($0) } }.pickerStyle(.menu)
                }
            } }
            if historySection == 0 {
                let visibleEvents = eventFilter == "All" ? monitor.events : monitor.events.filter { $0.kind == eventFilter }
                Text("\(visibleEvents.count) events · recorded as they happen").font(.subheadline)
                if visibleEvents.isEmpty { panel { Text("No events match this filter for this day.").font(.subheadline) } }
                ForEach(Array(visibleEvents.reversed())) { event in
                    panel { VStack(alignment: .leading, spacing: 9) {
                        timestamp(event.time, tint: event.kind == "alarm" ? coral : lavender)
                        Label(event.title, systemImage: event.kind == "alarm" ? "bell.fill" : event.kind == "note" ? "note.text" : "antenna.radiowaves.left.and.right").font(.headline)
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
                            HStack { Text(sample.heartRate.map { "\($0) bpm" } ?? "HR —").foregroundStyle(coral); Spacer(); Text(sample.oxygen.map { "O₂ \($0)%" } ?? "O₂ —").foregroundStyle(teal) }.font(.title3.bold())
                            Text(sample.source == "experimental-custom" ? "Experimental adapter reading · verify independently" : "Standard Bluetooth reading").font(.caption).foregroundStyle(.white.opacity(0.7))
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
                        HStack { VStack(alignment: .leading) { Text(monitor.deviceNames[p.identifier] ?? p.name ?? "Unnamed Bluetooth device").font(.headline); Text("Tap to start a continuous session").font(.caption) }; Spacer(); Image(systemName: "chevron.right") }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                    }.buttonStyle(.bordered).disabled(monitor.active)
                    Button { toggleFavourite(p) } label: { Image(systemName: isFavourite(p) ? "star.fill" : "star").foregroundStyle(isFavourite(p) ? .yellow : .white.opacity(0.7)).padding(12) }.accessibilityLabel(isFavourite(p) ? "Remove favourite device" : "Favourite device")
                }
            }
            Text("Choose your Bluetooth heart-rate device. Star a device to keep it at the top of the list. Standard Heart Rate Service devices are supported; custom formats are experimental. If a device does not advertise its services, enable Show other nearby devices and scan again. Close other Bluetooth apps before connecting.").font(.caption).foregroundStyle(.white.opacity(0.7))
            Toggle("Show other nearby Bluetooth devices", isOn: $monitor.showAllDevices)
                .disabled(monitor.active || monitor.isScanning)
            panel { VStack(alignment: .leading, spacing: 10) {
                Text("CONNECTION STATUS").font(.caption.bold())
                Text(monitor.status).fixedSize(horizontal: false, vertical: true)
                Text("\(monitor.readings.reduce(0) { $0 + $1.count }) packets received").font(.headline)
                Text(monitor.measurementStatus).font(.caption)
                if let time = monitor.lastSample { Text("Last packet: \(time.formatted(date: .omitted, time: .standard))").font(.caption) }
            } }
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

    private var settings: some View { VStack(alignment: .leading, spacing: 18) {
        Text("Settings").font(.largeTitle.bold())
        Text("Nivvi 0.6 · Build 6").font(.caption).foregroundStyle(.secondary)
        panel { VStack(alignment: .leading, spacing: 10) {
            HStack { Label("Child profile", systemImage: "person.crop.circle"); Spacer(); Button("Edit") { showProfile = true }.buttonStyle(.bordered) }
            Text("\(displayName)\(ageText.isEmpty ? "" : " · \(ageText)")").font(.headline)
            Text("Stored on this iPhone by default.").font(.caption).foregroundStyle(.white.opacity(0.6))
        } }
        panel { VStack(alignment: .leading, spacing: 10) {
            Label("Family circle", systemImage: "person.3.fill")
            Text("Share saved readings and event logs using the CSV exports in History.").font(.caption)
            Text("Live remote sharing is not enabled in this build. Readings remain on this iPhone; use the History exports to share saved records.").font(.caption).foregroundStyle(.white.opacity(0.7))
        } }
        panel { VStack(alignment: .leading, spacing: 12) {
            Text("Heart-rate alarm ranges").font(.headline)
            HStack(spacing: 8) {
                Text("LOW").foregroundStyle(coral).frame(maxWidth: .infinity)
                Text("WITHIN LIMITS").foregroundStyle(teal).frame(maxWidth: .infinity)
                Text("HIGH").foregroundStyle(coral).frame(maxWidth: .infinity)
            }.font(.caption.bold()).padding(.vertical, 8).background(.white.opacity(0.08)).clipShape(Capsule())
            Text("Within limits means between your configured low and high limits; it is not a health assessment. Limits come from your child’s care plan; Nivvi does not set them for you.").font(.caption)
            Text("Custom-format values are experimental. Enable the test switch only to trial the mapped value against your care plan; verify readings independently.").font(.caption)
            Toggle("Experimental custom alarm test", isOn: $monitor.experimentalCustomAlarms).tint(lavender)
                .onChange(of: monitor.experimentalCustomAlarms) { _ in monitor.silenceAlarm() }
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
            Text("Enter limits from your child’s care plan. Each enabled limit must be crossed for the selected duration with continuous valid samples. Gaps restart the timer. Settings stay saved on this phone.").font(.caption)
            Button(monitor.testingSiren ? "Stop test siren" : "Test siren for 5 seconds") { monitor.testSiren() }
                .buttonStyle(.borderedProminent).tint(coral).disabled(monitor.alarmActive)
            Button("Test notification in 10 seconds") { monitor.testNotification() }.buttonStyle(.bordered)
            Text(monitor.soundStatus).font(.caption)
            Text(monitor.notificationStatus).font(.caption)
            Text("Low alarms fire strictly below the low limit; high alarms fire strictly above the high limit. The alarm self-clears after a fresh in-range reading. Lock-screen sounds depend on iPhone volume, Silent mode, Focus and notification permissions; Critical Alerts approval is not included.").font(.caption).foregroundStyle(.white.opacity(0.7))
        } }
        panel { VStack(alignment: .leading, spacing: 10) {
            Label("Continuous Bluetooth session", systemImage: "antenna.radiowaves.left.and.right")
            Text("Keeps the Bluetooth session active and attempts reconnection after signal loss. Tap Disconnect to end the session.").font(.caption)
            Text("Background readings require device notifications. Keep Nivvi open if the wearable only responds to reads. Force-quitting the app, Bluetooth being off, an empty battery or iOS restrictions can interrupt monitoring.").font(.caption).foregroundStyle(.white.opacity(0.7))
        } }
        panel { Label("Day/night mode", systemImage: "sun.and.horizon.fill"); Text("Automatic mode follows local time. This setting does not detect sleep.").font(.caption).foregroundStyle(.white.opacity(0.6)) }
        panel { Label("Privacy", systemImage: "lock.fill"); Text("No account required. Readings and notes are saved on this iPhone. Exports are shared only when you choose.").font(.caption).foregroundStyle(.white.opacity(0.6)) }
    } }

    private var bottomBar: some View { HStack { nav("house.fill", "Home", 0); nav("chart.xyaxis.line", "History", 1); nav("wave.3.right", "Device", 2); nav("gearshape.fill", "Settings", 3) }.padding(8).background(.white.opacity(0.1)).clipShape(Capsule()).padding(.horizontal, 18).padding(.bottom, 10) }
    private func nav(_ icon: String, _ title: String, _ index: Int) -> some View { Button { withAnimation(.easeInOut(duration: 0.2)) { tab = index } } label: { VStack(spacing: 4) { Image(systemName: icon); Text(title).font(.caption2) }.foregroundStyle(tab == index ? lavender : .white.opacity(0.65)).frame(maxWidth: .infinity).padding(.vertical, 8).background(tab == index ? .white.opacity(0.12) : .clear).clipShape(Capsule()) } }
    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View { content().padding(18).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.09)).clipShape(RoundedRectangle(cornerRadius: 22)) }
    private func readingCard(_ title: String, _ value: String, _ note: String, _ icon: String, _ tint: Color) -> some View { VStack(alignment: .leading, spacing: 10) { Image(systemName: icon).foregroundStyle(tint); Text(title).font(.subheadline); Text(value).font(.headline); Text(note).font(.caption2).foregroundStyle(.white.opacity(0.55)) }.padding(16).frame(maxWidth: .infinity, minHeight: 150, alignment: .leading).background(.white.opacity(0.09)).clipShape(RoundedRectangle(cornerRadius: 22)) }
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
