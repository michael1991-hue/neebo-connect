import SwiftUI
import CoreBluetooth
import AudioToolbox
import AVFoundation
import UserNotifications
import Charts

struct Reading: Identifiable {
    let id: String
    var count: Int
    var hex: String
}

enum DeviceProfile: String {
    case nbo = "NBO custom wearable"
    case heartRate = "Standard heart-rate device"
    case pulseOximeter = "Standard pulse oximeter"
    case thermometer = "Standard thermometer"
    case generic = "Bluetooth device"
    case unknown = "Profile not identified"
}

struct SavedMeasurement: Codable, Identifiable {
    var id: UUID = UUID()
    let time: Date
    let heartRate: Int?
    let oxygen: Int?
    let source: String
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
        case .receiving: return "Connected · receiving data"
        case .stopping: return "Disconnecting…"
        }
    }
}
enum BluetoothPolicy {
    static func normalized(_ value: String) -> String {
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if result.hasPrefix("0000"), result.hasSuffix("-0000-1000-8000-00805F9B34FB") {
            return String(result.dropFirst(4).prefix(4))
        }
        return result
    }
    static func isCandidate(names: [String], services: [String]) -> Bool {
        let names = names.map(normalized)
        if names.contains("NC0") || names.contains("NCO") { return false }
        return names.contains { ["NB0", "NBO", "NEEBO"].contains($0) } || services.map(normalized).contains { ["FFE0", "FFA0"].contains($0) }
    }
    static func shouldObserve(service: String, characteristic: String) -> Bool {
        let service = normalized(service), characteristic = normalized(characteristic)
        switch service {
        case "FFE0": return ["FFE7", "FFEA", "FFE4"].contains(characteristic)
        case "180F": return characteristic == "2A19"
        case "180D": return characteristic == "2A37"
        default: return false
        }
    }
    static func ffe7(_ data: Data) -> (heartRate: Int?, oxygen: Int?) {
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
    private var lastFFE7: Date?
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
    @Published var verifiedHeartRate: Int?
    @Published var verifiedOxygen: Int?
    @Published var ffe7HeartRateCandidate: Int?
    @Published var ffe7OxygenCandidate: Int?
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
    @Published var testingSiren = false
    private var alarmEngine = RateAlarmEngine()
    private var siren: AVAudioPlayer?
    private var soundTestTimer: Timer?
    private var retryTimer: Timer?
    private var retrySeconds: TimeInterval = 2
    private var session = SessionIntent()
    private var foreground = UIApplication.shared.applicationState == .active
    @Published var history: [SavedMeasurement] = []
    @Published var historyDays: [Date] = []
    @Published var selectedHistoryDay = Calendar.current.startOfDay(for: Date())
    @Published var measurementTime: Date?
    @Published var historyError: String?
    private var historyLoadFailed = false
    private var freshnessTimer: Timer?
    private lazy var archive = DailyHistoryStore(folder: folder)
    private var historyURL: URL { folder.appendingPathComponent("measurements.json") }
    private func saveMeasurement(heartRate: Int?, oxygen: Int?, source: String) {
        let entry = SavedMeasurement(time: Date(), heartRate: heartRate, oxygen: oxygen, source: source)
        measurementTime = entry.time
        guard !historyLoadFailed else { return }
        do {
            try archive.append(entry)
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
    }
    func clearHistory() {
        do {
            try archive.clear(legacy: historyURL)
            history = []; historyDays = []; historyError = nil; historyLoadFailed = false
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("Nivvi-history.csv"))
        } catch { historyError = "History could not be fully cleared: \(error.localizedDescription)" }
    }
    func exportHistory() -> URL? {
        let url = folder.appendingPathComponent("Nivvi-history.csv")
        do { try archive.export(to: url); return url }
        catch { historyError = "Export failed: \(error.localizedDescription)"; return nil }
    }
    private func clearLiveValues() {
        verifiedHeartRate = nil; verifiedOxygen = nil
        ffe7HeartRateCandidate = nil; ffe7OxygenCandidate = nil
        measurementTime = nil; lastFFE7 = nil
        alarmEngine.interrupt()
    }
    private func expireMeasurements() {
        guard let time = measurementTime, Date().timeIntervalSince(time) > 30 else { return }
        clearLiveValues()
        if active { status = "No fresh measurements — check the connection."; measurementStatus = "Measurements expired after 30 seconds without usable values." }
    }
    private var manager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var file: FileHandle?
    private var deadline: Timer?
    private var captureEndsAt: Date?
    private let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: "nivvi.alarms"), let saved = try? JSONDecoder().decode(AlarmSettings.self, from: data) { alarmSettings = saved }
        session.deviceID = UserDefaults.standard.string(forKey: "nivvi.session.device").flatMap(UUID.init(uuidString:))
        session.enabled = UserDefaults.standard.bool(forKey: "nivvi.session.enabled")
        UNUserNotificationCenter.current().delegate = self
        // Instantiate at launch with the same identifier, including a Bluetooth restoration launch.
        manager = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionRestoreIdentifierKey: "nivvi.wearable.session"])
        refreshFiles(); refreshNotificationStatus()
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
            manager.scanForPeripherals(withServices: [CBUUID(string: "FFE0"), CBUUID(string: "FFA0"), CBUUID(string: "180D")])
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
        let connected = manager.retrieveConnectedPeripherals(withServices: [CBUUID(string: "FFE0"), CBUUID(string: "FFA0")])
        for p in connected {
            if BluetoothPolicy.isCandidate(names: [p.name ?? ""], services: ["FFE0"]) { addDevice(p, name: p.name ?? "Wearable already connected to iPhone") }
        }
        manager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        scanDeadline = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            guard let self = self, self.scanToken == token, self.connection == .scanning else { return }
            self.manager.stopScan(); self.connection = .idle
            self.status = self.devices.isEmpty ? "No wearable found. Disconnect LightBlue, keep the wearable close, then scan again. Try Show other nearby devices if its name differs." : "Tap a device below to connect."
        }
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if session.enabled { resumeSession() }
            else if !active { status = "Bluetooth ready — scan for your wearable." }
        case .poweredOff, .unauthorized, .unsupported:
            scanToken = UUID(); scanDeadline?.invalidate(); resetTransport()
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
        battery = "—"; counter = "—"; readings = []; diagnostics = []; lastSample = nil; lastFFE7 = nil; recording = nil
        profile = .unknown; verifiedHeartRate = nil; verifiedOxygen = nil; ffe7HeartRateCandidate = nil; ffe7OxygenCandidate = nil
        measurementTime = nil; measurementStatus = "Waiting for a Bluetooth connection."
        do {
            let url = folder.appendingPathComponent("NB0-\(UUID().uuidString).jsonl")
            try Data().write(to: url)
            file = try FileHandle(forWritingTo: url); recording = url
        } catch { status = "Cannot create recording: \(error.localizedDescription)"; return }
        session.start(p.identifier); saveSession()
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
        p.discoverServices(nil)
        noDataTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            guard let self = self, self.owns(p) else { return }
            if self.lastSample == nil { self.status = "Connected, but no values received. Check Connection details." }
            else if self.lastFFE7 == nil && self.profile == .nbo { self.measurementStatus = "Battery/status received, but no FFE7 measurements yet." }
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
        notify(title: "Nivvi connection lost", body: "No live measurements. Reconnecting to the wearable automatically.", identifier: "nivvi-connection", sirenSound: false)
        if central.state == .poweredOn { resumeSession() }
        else { connection = .bluetoothOff }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard owns(p) else { return }
        if let error = error { note("Service discovery failed: \(error.localizedDescription)"); status = "Service discovery failed. Stop and reconnect."; return }
        let services = Set((p.services ?? []).map { BluetoothPolicy.normalized($0.uuid.uuidString) })
        note("Services: \(services.sorted().joined(separator: ", "))")
        if services.contains("FFE0") || services.contains("FFA0") { profile = .nbo }
        else if services.contains("180D") { profile = .heartRate }
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
            note("Found \(sid)/\(cid): read=\(c.properties.contains(.read)), notify=\(c.properties.contains(.notify))")
            if sid == "FFE0" && cid == "FFE7" {
                measurementCharacteristic = c
                measurementStatus = "FFE7 found. Requesting measurements…"
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
        if c === measurementCharacteristic && error != nil { measurementStatus = "FFE7 notifications failed; trying readable values instead." }
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard owns(p) else { return }
        if c === pendingRead { pendingRead = nil }
        defer { readNext() }
        if let error = error { note("Read failed for \(c.uuid.uuidString): \(error.localizedDescription)"); return }
        guard let data = c.value else { return }
        let uuid = BluetoothPolicy.normalized(c.uuid.uuidString)
        let serviceID = BluetoothPolicy.normalized(c.service?.uuid.uuidString ?? "")
        let hex = data.map { String(format: "%02x", $0) }.joined()
        log(["event": "sample", "uuid": uuid, "service": serviceID, "hex": hex])
        lastSample = Date(); connection = .receiving
        status = "Receiving device data. The session stays on until you disconnect."
        let key = (c.service?.uuid.uuidString ?? "?") + "/" + uuid
        if uuid == "2A37", serviceID == "180D" {
            guard data.count >= 2 else { verifiedHeartRate = nil; alarmEngine.interrupt(); return }
            let wide = (data[0] & 1) != 0
            guard !wide || data.count >= 3 else { verifiedHeartRate = nil; alarmEngine.interrupt(); return }
            let bpm = wide ? Int(data[1]) | (Int(data[2]) << 8) : Int(data[1])
            guard bpm > 0 && bpm < 300 else {
                verifiedHeartRate = nil; alarmEngine.interrupt()
                return
            }
            verifiedHeartRate = bpm
            saveMeasurement(heartRate: bpm, oxygen: nil, source: "standard-2A37")
            evaluateRateAlarm(bpm)
        }
        // NB0's custom FFE7 sample has matched the live inspector captures as:
        // 00 00 00 [heart-rate candidate] 00 [oxygen candidate] ...
        // Keep these separate from verified standard BLE measurements until a
        // timed comparison with Neebo confirms the field meanings.
        if uuid == "FFE7", serviceID == "FFE0" {
            lastFFE7 = Date()
            let candidate = BluetoothPolicy.ffe7(data)
            ffe7HeartRateCandidate = candidate.heartRate
            ffe7OxygenCandidate = candidate.oxygen
            measurementStatus = candidate.heartRate == nil && candidate.oxygen == nil ? "FFE7 received (\(data.count) bytes), but values or frame format are not recognised." : "Experimental FFE7 values received; compare against Neebo."
            if candidate.heartRate != nil || candidate.oxygen != nil {
                saveMeasurement(heartRate: candidate.heartRate, oxygen: candidate.oxygen, source: "experimental-FFE7")
            }
        }
        // 2A5E/2A5F are standard pulse-ox measurements. Values stay hidden until
        // a complete standards-compliant parser is added; never infer from raw bytes.
        if let i = readings.firstIndex(where: { $0.id == key }) {
            readings[i].count += 1; readings[i].hex = hex
        } else { readings.append(Reading(id:key, count:1, hex:hex)) }
        if uuid == "2A19", serviceID == "180F", data.count == 1, data[0] <= 100 { battery = "\(data[0])%" }
        if uuid == "FFEA", data.count == 2 { counter = "\(Int(data[0]) | (Int(data[1]) << 8)) — possible minutes" }
    }
    private func evaluateRateAlarm(_ bpm: Int) {
        let event = alarmEngine.ingest(bpm: bpm, source: "standard-2A37", at: Date(), settings: alarmSettings)
        alarmKind = alarmEngine.active
        if let event = event {
            startSiren(loop: true)
            notify(title: event.title, body: "\(bpm) bpm crossed your configured limit. Check your child and follow their care plan.", identifier: "nivvi-rate-alarm")
            status = event.title + " — check your child and follow their care plan."
        } else if !alarmActive && !testingSiren { stopSiren() }
    }
    func silenceAlarm() {
        alarmEngine.silence(); alarmKind = nil; stopSiren()
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["nivvi-rate-alarm"])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["nivvi-rate-alarm"])
        soundStatus = "Silenced. The same excursion stays muted until a new in-range reading or a different limit is reached."
    }
    func stop() {
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
    @FocusState private var editingName: Bool
    private let save: (String, Date, String) -> Void
    private let canCancel: Bool
    private let genders = ["Girl", "Boy", "Other", "Prefer not to say"]

    init(name: String, birthDate: Date, gender: String, save: @escaping (String, Date, String) -> Void) {
        _name = State(initialValue: name)
        _birthDate = State(initialValue: min(birthDate, Date()))
        _gender = State(initialValue: gender)
        self.save = save
        canCancel = !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var body: some View {
        NavigationStack {
            Form {
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
                        save(name.trimmingCharacters(in: .whitespacesAndNewlines), birthDate, gender)
                        dismiss()
                    }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
    }
}

struct CaptureRequest: Identifiable {
    let id = UUID()
    let peripheral: CBPeripheral
}

struct ContentView: View {
    @ObservedObject var monitor: Monitor
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("nivvi.profile.name") private var childName = ""
    @AppStorage("nivvi.profile.birthDate") private var childBirthDate = 0.0
    @AppStorage("nivvi.profile.gender") private var childGender = "Prefer not to say"
    @AppStorage("nivvi.demo.mode") private var demoMode = false
    @State private var showProfile = false
    @State private var captureRequest: CaptureRequest?
    @State private var tab = 0
    @State private var historyExport: URL?
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
    private var heartRateDisplay: String { (monitor.verifiedHeartRate ?? monitor.ffe7HeartRateCandidate).map { "\($0) bpm" } ?? "Not decoded" }
    private var oxygenDisplay: String { (monitor.verifiedOxygen ?? monitor.ffe7OxygenCandidate).map { "\($0)%" } ?? "Not decoded" }
    private var liveMeasurementNote: String {
        if monitor.verifiedHeartRate != nil || monitor.verifiedOxygen != nil { return "Standard Bluetooth value" }
        if monitor.ffe7HeartRateCandidate != nil || monitor.ffe7OxygenCandidate != nil { return "FFE7 candidate · confirm against Neebo" }
        return monitor.profile == .heartRate ? "Waiting for verified data" : "Waiting for device data"
    }
    private var demoHistory: [TrendSample] { [TrendSample(id: "mon", day: "Mon", heartRate: 86, oxygen: 98), TrendSample(id: "tue", day: "Tue", heartRate: 88, oxygen: 99), TrendSample(id: "wed", day: "Wed", heartRate: 87, oxygen: 99), TrendSample(id: "thu", day: "Thu", heartRate: 90, oxygen: 98), TrendSample(id: "fri", day: "Fri", heartRate: 88, oxygen: 99), TrendSample(id: "sat", day: "Sat", heartRate: 85, oxygen: 99), TrendSample(id: "sun", day: "Sun", heartRate: 88, oxygen: 99)] }
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
                Text("Nivvi will stay connected and try to reconnect after signal loss until you tap Disconnect. Connecting may interrupt the original monitor. NBO readings remain experimental and do not trigger alarms.")
                Button("Connect wearable") {
                    monitor.connect(request.peripheral)
                    captureRequest = nil
                    tab = 2
                }.buttonStyle(.borderedProminent).controlSize(.large)
                Button("Cancel") { captureRequest = nil }
            }.padding(24).presentationDetents([.medium])
        }
        .onAppear { if childName.isEmpty { showProfile = true } }
        .sheet(isPresented: $showProfile) {
            ProfileSetupView(name: childName, birthDate: birthDate, gender: childGender) { name, date, gender in
                childName = name; childBirthDate = date.timeIntervalSince1970; childGender = gender
            }
        }
        .onChange(of: scenePhase) { phase in monitor.applicationActive(phase == .active) }
        .onAppear { monitor.applicationActive(scenePhase == .active) }
        .scrollDismissesKeyboard(.interactively)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
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
                Circle().fill(connected ? teal : .gray).frame(width: 11, height: 11)
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
            HStack(alignment: .firstTextBaseline) { Text(connected ? "Live device session" : "Ready to connect").font(.title2.bold()); Spacer(); Image(systemName: mode.symbol).foregroundStyle(mode == .night ? lavender : .yellow) }
            HStack(spacing: 14) {
                readingCard("Heart rate", heartRateDisplay, liveMeasurementNote, "heart.fill", coral)
                readingCard("Oxygen", oxygenDisplay, liveMeasurementNote, "lungs.fill", teal)
            }
            HStack(spacing: 14) {
                smallCard("Temperature", "Not decoded", "thermometer.medium", lavender)
                smallCard("Sleep", "No data", "bed.double.fill", coral)
            }
            Button { monitor.selectHistoryDay(Date()); tab = 1 } label: {
                HStack { Text("View today’s story").font(.headline); Spacer(); Image(systemName: "arrow.right") }
                    .foregroundStyle(Color(red: 0.06, green: 0.16, blue: 0.25)).padding(18).frame(maxWidth: .infinity)
                    .background(lavender).clipShape(RoundedRectangle(cornerRadius: 20))
            }
            if !monitor.status.isEmpty { Text(monitor.status).font(.caption).foregroundStyle(.white.opacity(0.6)).fixedSize(horizontal: false, vertical: true) }
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("History").font(.largeTitle.bold())
            Text("Your recordings stay on this iPhone").foregroundStyle(.white.opacity(0.65))
            if demoMode {
                panel { VStack(alignment: .leading, spacing: 12) {
                    HStack { Text("DEMO TREND · EXAMPLE DATA").font(.caption.bold()).foregroundStyle(.white.opacity(0.55)); Spacer(); Text("Not live").font(.caption.bold()).foregroundStyle(coral) }
                    Text("Overnight heart rate").font(.title3.bold())
                    Chart(demoHistory) { sample in
                        LineMark(x: .value("Day", sample.day), y: .value("BPM", sample.heartRate)).foregroundStyle(coral)
                        PointMark(x: .value("Day", sample.day), y: .value("BPM", sample.heartRate)).foregroundStyle(coral)
                    }.chartYScale(domain: 80...95).chartXAxis { AxisMarks() }.chartYAxis { AxisMarks(position: .leading) }.frame(height: 180)
                    Text("Example trend for exploring the interface. Live readings appear only after a verified device is connected.").font(.caption).foregroundStyle(.white.opacity(0.65))
                } }
            } else {
                panel { VStack(alignment: .leading, spacing: 14) {
                    Text("RECORDED MEASUREMENTS").font(.headline)
                    Text("Last 30 calendar days, stored on this iPhone. FFE7 readings are experimental.").font(.caption)
                    DatePicker("History day", selection: Binding(get: { monitor.selectedHistoryDay }, set: { monitor.selectHistoryDay($0) }), in: ...Date(), displayedComponents: .date)
                        .datePickerStyle(.compact)
                    Text("\(monitor.history.count) readings on this day · \(monitor.historyDays.count) recorded days").font(.caption)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack { ForEach(monitor.historyDays, id: \.self) { day in
                            Button(day.formatted(date: .abbreviated, time: .omitted)) { monitor.selectHistoryDay(day) }.buttonStyle(.bordered)
                        } }
                    }
                    if monitor.history.isEmpty { Text("No saved measurements for this day.") }
                    else {
                        Chart(DailyHistoryStore.chartSamples(monitor.history)) { sample in
                            if let bpm = sample.heartRate {
                                LineMark(x: .value("Time", sample.time), y: .value("BPM", bpm), series: .value("Source", sample.source)).foregroundStyle(coral)
                            }
                        }.frame(height: 180)
                        Chart(DailyHistoryStore.chartSamples(monitor.history)) { sample in
                            if let oxygen = sample.oxygen {
                                LineMark(x: .value("Time", sample.time), y: .value("Oxygen %", oxygen), series: .value("Source", sample.source)).foregroundStyle(teal)
                            }
                        }.frame(height: 140)
                        ForEach(Array(monitor.history.suffix(20).reversed())) { sample in
                            VStack(alignment: .leading) {
                                Text(sample.time.formatted(date: .abbreviated, time: .standard)).font(.caption)
                                Text("HR \(sample.heartRate.map(String.init) ?? "—") bpm · O₂ \(sample.oxygen.map(String.init) ?? "—")%")
                                Text(sample.source).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if !monitor.historyDays.isEmpty {
                        Button("Prepare all 30 days as CSV") { historyExport = monitor.exportHistory() }
                        if let url = historyExport { ShareLink("Share history CSV", item: url) }
                        Button("Delete history", role: .destructive) { confirmDeleteHistory = true }
                            .confirmationDialog("Delete all saved measurement history?", isPresented: $confirmDeleteHistory) {
                                Button("Delete", role: .destructive) { monitor.clearHistory(); historyExport = nil }
                            }
                    }
                    if let error = monitor.historyError { Text(error).foregroundStyle(coral) }
                } }
            }
            panel { VStack(alignment: .leading, spacing: 12) { Text("RAW CAPTURE").font(.caption.bold()).foregroundStyle(.white.opacity(0.55)); Text("\(monitor.readings.reduce(0) { $0 + $1.count }) samples").font(.title3.bold()); ForEach(monitor.readings.prefix(4)) { r in Text("\(r.id) · \(r.count) packets").font(.caption.monospaced()).foregroundStyle(.white.opacity(0.7)) } } }
        }
    }

    private var device: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Device").font(.largeTitle.bold())
            panel { HStack(spacing: 14) { Image(systemName: "wave.3.right.circle.fill").font(.largeTitle).foregroundStyle(teal); VStack(alignment: .leading) { Text("NBO wearable").font(.headline); Text(monitor.connection.label).foregroundStyle(connected ? teal : .white.opacity(0.6)) }; Spacer() } }
            panel { VStack(alignment: .leading, spacing: 6) { Text("PROFILE").font(.caption.bold()).foregroundStyle(.white.opacity(0.55)); Text(monitor.profile.rawValue).font(.headline); Text("Nivvi only displays measurements when the Bluetooth format is recognised.").font(.caption).foregroundStyle(.white.opacity(0.6)) } }
            HStack(spacing: 14) { metric("Battery", monitor.battery == "—" ? "—" : monitor.battery); metric("Mode", mode.rawValue) }
            Button { monitor.active ? monitor.stop() : monitor.scan() } label: { Text(monitor.active ? "Disconnect" : (monitor.isScanning ? "Scanning…" : "Scan for NBO")).font(.headline).frame(maxWidth: .infinity).padding(17) }.buttonStyle(.borderedProminent).tint(coral).disabled(monitor.isScanning)
            ForEach(monitor.devices, id: \.identifier) { p in
                Button {
                    captureRequest = CaptureRequest(peripheral: p)
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(monitor.deviceNames[p.identifier] ?? p.name ?? "Unnamed Bluetooth device").font(.headline)
                            Text("Tap to start a continuous session").font(.caption)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                }.buttonStyle(.bordered).disabled(monitor.active)
            }
            Text("Select the wearable named NB0 (zero) or NBO (letter O). Disconnect LightBlue before connecting Nivvi. The first two minutes of each session also create a diagnostic log.").font(.caption).foregroundStyle(.white.opacity(0.7))
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
        Text("Nivvi 0.3 · Build 3").font(.caption).foregroundStyle(.secondary)
        panel { VStack(alignment: .leading, spacing: 10) {
            HStack { Label("Child profile", systemImage: "person.crop.circle"); Spacer(); Button("Edit") { showProfile = true }.buttonStyle(.bordered) }
            Text("\(displayName)\(ageText.isEmpty ? "" : " · \(ageText)")").font(.headline)
            Text("Stored on this iPhone by default.").font(.caption).foregroundStyle(.white.opacity(0.6))
        } }
        panel { VStack(alignment: .leading, spacing: 10) {
            Toggle("Demo mode", isOn: $demoMode).tint(teal)
            Text("Shows clearly labelled example readings for exploring Nivvi. Demo data never triggers alarms or uploads to CloudKit.").font(.caption).foregroundStyle(.white.opacity(0.6))
        } }
        panel { VStack(alignment: .leading, spacing: 10) {
            Label("Family sharing", systemImage: "person.3.fill")
            Text("Export a history CSV from History to share with a caregiver. Live remote sharing is not available.").font(.caption)
        } }
        panel { VStack(alignment: .leading, spacing: 12) {
            Text("Heart-rate test alarms").font(.headline)
            Text("Standard heart-rate devices only. NBO FFE7 automatic alarms stay unavailable while the mapping is experimental.").font(.caption)
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
            Text("Foreground alarms repeat until silenced or a fresh reading returns within your limits. Lock-screen notifications use an 8-second siren. Silent mode, Focus and notification volume can suppress that sound; this build has no Critical Alerts approval.").font(.caption).foregroundStyle(.white.opacity(0.7))
        } }
        panel { VStack(alignment: .leading, spacing: 10) {
            Label("Continuous Bluetooth session", systemImage: "antenna.radiowaves.left.and.right")
            Text("Stays connected when you lock the phone. Automatically reconnects when the wearable returns to range. Tap Disconnect to end the session.").font(.caption)
            Text("Background readings require device notifications. Keep Nivvi open if the wearable only responds to reads. Force-quitting the app, Bluetooth being off, an empty battery or iOS restrictions can interrupt monitoring.").font(.caption).foregroundStyle(.white.opacity(0.7))
        } }
        panel { Label("Day/night mode", systemImage: "sun.and.horizon.fill"); Text("Automatic mode follows local time. Sleep detection will be added once movement data is decoded.").font(.caption).foregroundStyle(.white.opacity(0.6)) }
        panel { Label("Privacy", systemImage: "lock.fill"); Text("No legacy login. No cloud history by default.").font(.caption).foregroundStyle(.white.opacity(0.6)) }
    } }

    private var bottomBar: some View { HStack { nav("house.fill", "Home", 0); nav("chart.xyaxis.line", "History", 1); nav("wave.3.right", "Device", 2); nav("gearshape.fill", "Settings", 3) }.padding(8).background(.white.opacity(0.1)).clipShape(Capsule()).padding(.horizontal, 18).padding(.bottom, 10) }
    private func nav(_ icon: String, _ title: String, _ index: Int) -> some View { Button { withAnimation(.easeInOut(duration: 0.2)) { tab = index } } label: { VStack(spacing: 4) { Image(systemName: icon); Text(title).font(.caption2) }.foregroundStyle(tab == index ? lavender : .white.opacity(0.65)).frame(maxWidth: .infinity).padding(.vertical, 8).background(tab == index ? .white.opacity(0.12) : .clear).clipShape(Capsule()) } }
    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View { content().padding(18).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.09)).clipShape(RoundedRectangle(cornerRadius: 22)) }
    private func readingCard(_ title: String, _ value: String, _ note: String, _ icon: String, _ tint: Color) -> some View { VStack(alignment: .leading, spacing: 10) { Image(systemName: icon).foregroundStyle(tint); Text(title).font(.subheadline); Text(value).font(.headline); Text(note).font(.caption2).foregroundStyle(.white.opacity(0.55)) }.padding(16).frame(maxWidth: .infinity, minHeight: 150, alignment: .leading).background(.white.opacity(0.09)).clipShape(RoundedRectangle(cornerRadius: 22)) }
    private func smallCard(_ title: String, _ value: String, _ icon: String, _ tint: Color) -> some View { HStack { Image(systemName: icon).foregroundStyle(tint); VStack(alignment: .leading) { Text(title).font(.subheadline); Text(value).font(.caption).foregroundStyle(.white.opacity(0.6)) } }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.09)).clipShape(RoundedRectangle(cornerRadius: 18)) }
    private func metric(_ title: String, _ value: String) -> some View { VStack(alignment: .leading) { Text(title).font(.caption).foregroundStyle(.white.opacity(0.55)); Text(value).font(.headline) }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.09)).clipShape(RoundedRectangle(cornerRadius: 18)) }
}

final class NivviAppDelegate: NSObject, UIApplicationDelegate {
    let monitor = Monitor()
}
@main
struct NivviApp: App {
    @UIApplicationDelegateAdaptor(NivviAppDelegate.self) private var delegate
    var body: some Scene { WindowGroup { ContentView(monitor: delegate.monitor) } }
}

