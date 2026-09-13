import SwiftUI
import CoreBluetooth
import AudioToolbox
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
    case idle, scanning, connecting, discovering, waiting, receiving, stopping
    var isConnected: Bool { [Self.discovering, .waiting, .receiving].contains(self) }
    var isBusy: Bool { [Self.connecting, .discovering, .waiting, .receiving, .stopping].contains(self) }
    var label: String {
        switch self {
        case .idle: return "Not connected"
        case .scanning: return "Scanning nearby"
        case .connecting: return "Connecting…"
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

final class Monitor: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var status = "Ready — foreground testing only"
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
    private func owns(_ p: CBPeripheral) -> Bool { p === peripheral && active && connection != .stopping }
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
    @Published var highRateAlarmEnabled = false
    @Published var highRateThreshold = 200
    @Published var highRateDurationSeconds = 15
    @Published var alarmActive = false
    @Published var history: [SavedMeasurement] = []
    @Published var measurementTime: Date?
    @Published var historyError: String?
    private var historyLoadFailed = false
    private var freshnessTimer: Timer?
    private var previousHeartRateTime: Date?
    private var highRateSince: Date?
    private var historyURL: URL { folder.appendingPathComponent("measurements.json") }
    private func saveMeasurement(heartRate: Int?, oxygen: Int?, source: String) {
        measurementTime = Date()
        guard !historyLoadFailed else { return }
        history.append(SavedMeasurement(time: Date(), heartRate: heartRate, oxygen: oxygen, source: source))
        // Bound local storage to the latest 20,000 readings.
        if history.count > 20_000 { history.removeFirst(history.count - 20_000) }
        do { try JSONEncoder().encode(history).write(to: historyURL, options: .atomic); historyError = nil }
        catch { historyError = "History could not be saved: \(error.localizedDescription)" }
    }
    func clearHistory() {
        do { try Data("[]".utf8).write(to: historyURL, options: .atomic); history = []; historyError = nil; historyLoadFailed = false
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("Nivvi-history.csv"))
        }
        catch { historyError = "History could not be cleared." }
    }
    func exportHistory() -> URL? {
        let url = folder.appendingPathComponent("Nivvi-history.csv")
        let formatter = ISO8601DateFormatter()
        let rows = history.map { "\(formatter.string(from: $0.time)),\($0.heartRate.map(String.init) ?? ""),\($0.oxygen.map(String.init) ?? ""),\($0.source)" }
        do { try ("time,heart_rate_bpm,oxygen_percent,source\n" + rows.joined(separator: "\n")).write(to: url, atomically: true, encoding: .utf8); return url }
        catch { historyError = "Export failed."; return nil }
    }
    private func expireMeasurements() {
        guard let time = measurementTime, Date().timeIntervalSince(time) > 30 else { return }
        verifiedHeartRate = nil; verifiedOxygen = nil
        ffe7HeartRateCandidate = nil; ffe7OxygenCandidate = nil
        highRateSince = nil; previousHeartRateTime = nil; alarmActive = false
        measurementTime = nil
        if active { status = "No fresh measurements — check the connection."; measurementStatus = "Measurements expired after 30 seconds without usable values." }
    }
    private var manager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var file: FileHandle?
    private var deadline: Timer?
    private let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    override init() {
        super.init()
        // Request notification permission only when the user enables test alerts.
        manager = CBCentralManager(delegate: self, queue: .main)
        refreshFiles()
        if FileManager.default.fileExists(atPath: historyURL.path) {
            do { history = try JSONDecoder().decode([SavedMeasurement].self, from: Data(contentsOf: historyURL)) }
            catch { historyLoadFailed = true; historyError = "Saved history could not be read. Original file preserved; new history storage is paused." }
        }
        freshnessTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.expireMeasurements() }
    }
    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge, .timeSensitive]) { _, _ in }
    }

    private func sendPriorityNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Nivvi high-rate alert"
        content.body = "Check your child and follow the cardiology plan."
        content.sound = .default
        if #available(iOS 15.0, *) { content.interruptionLevel = .timeSensitive }
        let request = UNNotificationRequest(identifier: "nivvi-high-rate-\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func refreshFiles() {
        files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
    func log(_ event: [String: String]) {
        var entry = event
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        entry["time"] = formatter.string(from: Date())
        do {
            var data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
            data.append(10)
            try file?.write(contentsOf: data)
        } catch { status = "Recording error: \(error.localizedDescription)"; stop() }
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
        if central.state != .poweredOn {
            scanToken = UUID(); scanDeadline?.invalidate()
            if let p = peripheral { central.cancelPeripheralConnection(p) }
            finish("Bluetooth unavailable.")
        }
        switch central.state {
        case .poweredOn: if !active { status = "Bluetooth ready — scan for your wearable." }
        case .unauthorized: status = "Allow Nivvi in Settings → Privacy & Security → Bluetooth."
        case .poweredOff: status = "Turn on Bluetooth in iPhone Settings."
        case .unsupported: status = "Bluetooth Low Energy is unavailable on this device."
        default: status = "Bluetooth is starting. Try again shortly."
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
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
        peripheral = p; p.delegate = self; connection = .connecting
        status = "Connecting to \(deviceNames[p.identifier] ?? p.name ?? "wearable")…"
        note("Connection requested; waiting for Bluetooth confirmation.")
        manager.connect(p)
        deadline = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
            guard let self = self, self.peripheral === p, self.connection == .connecting else { return }
            self.endCapture("Connection timed out. Disconnect LightBlue and the original monitor app from the wearable, then try again.")
        }
    }
    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        guard owns(p), connection == .connecting else { central.cancelPeripheralConnection(p); return }
        deadline?.invalidate(); connection = .discovering
        status = "Connected. Discovering battery and measurement services…"
        note("Bluetooth connection established.")
        p.discoverServices(nil)
        deadline = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in
            guard let self = self, self.peripheral === p else { return }
            self.endCapture("Two-minute capture complete. Your log is ready to share.")
        }
        noDataTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            guard let self = self, self.owns(p) else { return }
            if self.lastSample == nil {
                self.status = "Connected, but no values received. Open Connection details below and share the log after stopping."
            } else if self.lastFFE7 == nil && self.profile == .nbo {
                self.measurementStatus = "Battery/status data received, but no FFE7 measurements yet."
            }
        }
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        guard p === peripheral else { return }
        note("Connection failed: \(error?.localizedDescription ?? "unknown error")")
        finish("Connection failed: \(error?.localizedDescription ?? "unknown error"). Disconnect other apps and try again.")
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard p === peripheral else { return }
        if connection == .stopping { finish(status); return }
        note("Disconnected: \(error?.localizedDescription ?? "connection closed")")
        finish("Disconnected. \(error?.localizedDescription ?? "Check the wearable and try again.")")
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
                    guard let self = self, self.owns(p) else { return }
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
        status = "Receiving device data. Keep Nivvi open for the two-minute test."
        let key = (c.service?.uuid.uuidString ?? "?") + "/" + uuid
        if uuid == "2A37", serviceID == "180D" {
            guard data.count >= 2 else { return }
            let wide = (data[0] & 1) != 0
            guard !wide || data.count >= 3 else { return }
            let bpm = wide ? Int(data[1]) | (Int(data[2]) << 8) : Int(data[1])
            guard bpm > 0 && bpm < 300 else {
                verifiedHeartRate = nil; highRateSince = nil; previousHeartRateTime = nil; alarmActive = false
                return
            }
            let now = Date()
            if let previous = previousHeartRateTime, now.timeIntervalSince(previous) > 10 { highRateSince = nil }
            previousHeartRateTime = now
            verifiedHeartRate = bpm
            saveMeasurement(heartRate: bpm, oxygen: nil, source: "standard-2A37")
            evaluateHighRateAlarm()
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
    private func evaluateHighRateAlarm() {
        guard highRateAlarmEnabled, active, let bpm = verifiedHeartRate else { highRateSince = nil; alarmActive = false; return }
        if bpm >= highRateThreshold {
            if highRateSince == nil { highRateSince = Date() }
            if let since = highRateSince, Date().timeIntervalSince(since) >= Double(highRateDurationSeconds), !alarmActive {
                alarmActive = true
                AudioServicesPlayAlertSound(SystemSoundID(1005))
                sendPriorityNotification()
                status = "High-rate threshold reached — check the child profile and follow the cardiology plan."
            }
        } else {
            highRateSince = nil
            alarmActive = false
        }
    }

    func silenceAlarm() {
        alarmActive = false
        highRateSince = nil
    }

    func stop() { endCapture("Capture stopped. Restore your original monitor connection after testing.") }
    private func endCapture(_ message: String) {
        scanToken = UUID(); scanDeadline?.invalidate(); manager.stopScan()
        deadline?.invalidate(); pollTimer?.invalidate(); noDataTimer?.invalidate()
        verifiedHeartRate = nil; verifiedOxygen = nil; ffe7HeartRateCandidate = nil; ffe7OxygenCandidate = nil
        silenceAlarm(); measurementTime = nil
        if let p = peripheral, p.state != .disconnected {
            connection = .stopping; status = message
            note(message); manager.cancelPeripheralConnection(p)
            // Keep ownership until didDisconnect so an old callback cannot end a new session.
        } else { finish(message) }
    }
    private func finish(_ message: String) {
        verifiedHeartRate = nil; verifiedOxygen = nil; ffe7HeartRateCandidate = nil; ffe7OxygenCandidate = nil
        measurementTime = nil; highRateSince = nil; previousHeartRateTime = nil; alarmActive = false
        connection = .idle; deadline?.invalidate(); deadline = nil
        pollTimer?.invalidate(); pollTimer = nil; noDataTimer?.invalidate(); noDataTimer = nil
        readQueue = []; pendingRead = nil; measurementCharacteristic = nil
        // Close first so a recording error cannot recurse into stop().
        let oldFile = file; file = nil
        try? oldFile?.synchronize(); try? oldFile?.close()
        peripheral = nil
        status = message
        measurementStatus = "Capture ended. Saved readings are in History."
        refreshFiles()
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
    @StateObject private var monitor = Monitor()
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
                Text("This two-minute test can interrupt the original monitor app. Start only when you are not relying on its alerts.")
                Button("Connect and start capture") {
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
        .onChange(of: scenePhase) { phase in if phase == .background && (monitor.active || monitor.isScanning) { monitor.stop() } }
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

    private var home: some View {
        VStack(alignment: .leading, spacing: 18) {
            if monitor.alarmActive {
                HStack(spacing: 12) {
                    Image(systemName: "bell.and.waves.fill").foregroundStyle(.white)
                    VStack(alignment: .leading, spacing: 3) { Text("High-rate alert").font(.headline); Text("Check the child profile and follow the cardiology plan.").font(.caption) }
                    Spacer()
                    Button("Silence") { monitor.silenceAlarm() }.buttonStyle(.bordered).tint(.white)
                }.padding(16).background(coral).clipShape(RoundedRectangle(cornerRadius: 20))
            }
            Text("CURRENT STATUS").font(.caption.weight(.bold)).tracking(1.2).foregroundStyle(.white.opacity(0.55))
            HStack(alignment: .firstTextBaseline) { Text(connected ? "Device capture" : "Ready to connect").font(.title2.bold()); Spacer(); Image(systemName: mode.symbol).foregroundStyle(mode == .night ? lavender : .yellow) }
            HStack(spacing: 14) {
                readingCard("Heart rate", heartRateDisplay, liveMeasurementNote, "heart.fill", coral)
                readingCard("Oxygen", oxygenDisplay, liveMeasurementNote, "lungs.fill", teal)
            }
            HStack(spacing: 14) {
                smallCard("Temperature", "Not decoded", "thermometer.medium", lavender)
                smallCard("Sleep", "No data", "bed.double.fill", coral)
            }
            Button { tab = 1 } label: {
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
                    Text("FFE7 readings are experimental. Latest 20,000 readings kept locally.").font(.caption)
                    if monitor.history.isEmpty { Text("Connect your device to record measurements.") }
                    else {
                        Chart(Array(monitor.history.suffix(300))) { sample in
                            if let bpm = sample.heartRate {
                                LineMark(x: .value("Time", sample.time), y: .value("BPM", bpm), series: .value("Source", sample.source)).foregroundStyle(coral)
                            }
                        }.frame(height: 180)
                        Chart(Array(monitor.history.suffix(300))) { sample in
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
                        Button("Prepare CSV export") { historyExport = monitor.exportHistory() }
                        if let url = historyExport { ShareLink("Share history CSV", item: url) }
                        Button("Delete history", role: .destructive) { confirmDeleteHistory = true }
                            .confirmationDialog("Delete saved measurement history?", isPresented: $confirmDeleteHistory) {
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
            Button { monitor.active ? monitor.stop() : monitor.scan() } label: { Text(monitor.active ? "Stop capture" : (monitor.isScanning ? "Scanning…" : "Scan for NBO")).font(.headline).frame(maxWidth: .infinity).padding(17) }.buttonStyle(.borderedProminent).tint(coral).disabled(monitor.isScanning)
            ForEach(monitor.devices, id: \.identifier) { p in
                Button {
                    captureRequest = CaptureRequest(peripheral: p)
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(monitor.deviceNames[p.identifier] ?? p.name ?? "Unnamed Bluetooth device").font(.headline)
                            Text("Tap to connect · two-minute capture").font(.caption)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                }.buttonStyle(.bordered).disabled(monitor.active)
            }
            Text("Select the wearable named NB0 (zero) or NBO (letter O). Disconnect LightBlue before starting a capture.").font(.caption).foregroundStyle(.white.opacity(0.7))
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
                ShareLink(item: url) { Label("Share capture log", systemImage: "square.and.arrow.up") }.disabled(monitor.active)
            }
        }
    }

    private var settings: some View { VStack(alignment: .leading, spacing: 18) {
        Text("Settings").font(.largeTitle.bold())
        Text("Nivvi 0.2 · Build 2").font(.caption).foregroundStyle(.secondary)
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
            Toggle("Standard-device test alarm", isOn: $monitor.highRateAlarmEnabled).tint(coral)
                .onChange(of: monitor.highRateAlarmEnabled) { enabled in monitor.silenceAlarm(); if enabled { monitor.requestNotificationPermission() } }
            Text("NBO FFE7 alerts are unavailable while the mapping is experimental. Foreground testing only.").font(.caption)
            Stepper("Threshold: \(monitor.highRateThreshold) bpm", value: $monitor.highRateThreshold, in: 120...260, step: 5)
            Stepper("Must stay high: \(monitor.highRateDurationSeconds) seconds", value: $monitor.highRateDurationSeconds, in: 5...120, step: 5)
            Text("Set these values only from your child’s cardiology or nursery plan. The alarm remains off until enabled, and only works with verified heart-rate data.").font(.caption).foregroundStyle(.white.opacity(0.6))
            Text("Nivvi sends a Time Sensitive iPhone notification and sound. Critical Alerts require Apple approval and cannot be guaranteed by an ordinary app.").font(.caption).foregroundStyle(.white.opacity(0.6))
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

@main
struct NivviApp: App { var body: some Scene { WindowGroup { ContentView() } } }

