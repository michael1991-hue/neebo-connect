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

final class Monitor: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var status = "Ready — foreground testing only"
    @Published var battery = "—"
    @Published var counter = "—"
    @Published var readings: [Reading] = []
    @Published var devices: [CBPeripheral] = []
    @Published var active = false
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
        if active { status = "No fresh measurements — check the connection." }
    }
    private var manager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var file: FileHandle?
    private var deadline: Timer?
    private let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    override init() {
        super.init()
        requestNotificationPermission()
        manager = CBCentralManager(delegate: self, queue: .main)
        refreshFiles()
        if FileManager.default.fileExists(atPath: historyURL.path) {
            do { history = try JSONDecoder().decode([SavedMeasurement].self, from: Data(contentsOf: historyURL)) }
            catch { historyLoadFailed = true; historyError = "Saved history could not be read. Original file preserved; new history storage is paused." }
        }
        freshnessTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.expireMeasurements() }
    }
    private func requestNotificationPermission() {
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
        guard manager.state == .poweredOn, !active else { return }
        devices = []
        status = "Scanning for NB0 for 10 seconds…"
        manager.scanForPeripherals(withServices: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self = self else { return }
            self.manager.stopScan()
            if !self.active { self.status = self.devices.isEmpty ? "NB0 not found. It may be connected to another phone." : "Select NB0 to capture." }
        }
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: status = "Bluetooth ready — tap Scan"
        case .unauthorized: status = "Allow Bluetooth in iPhone Settings for this app."
        case .poweredOff: status = "Turn on Bluetooth in Settings."
        default: status = "Bluetooth unavailable or starting."
        }
        if central.state != .poweredOn && active { stop() }
    }
    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? p.name ?? "").uppercased()
        if ["NB0", "NBO"].contains(name), !devices.contains(where: { $0.identifier == p.identifier }) { devices.append(p) }
    }
    func connect(_ p: CBPeripheral) {
        guard !active else { return }
        manager.stopScan()
        battery = "—"; counter = "—"; readings = []; lastSample = nil; recording = nil; profile = .unknown; verifiedHeartRate = nil; verifiedOxygen = nil; ffe7HeartRateCandidate = nil; ffe7OxygenCandidate = nil
        do {
            let url = folder.appendingPathComponent("NB0-\(UUID().uuidString).jsonl")
            try Data().write(to: url)
            file = try FileHandle(forWritingTo: url)
            recording = url
        } catch { status = "Cannot create recording: \(error.localizedDescription)"; return }
        active = true; peripheral = p; p.delegate = self
        log(["event":"session", "device":p.name ?? "NB0", "id":p.identifier.uuidString])
        status = "Connecting…"
        manager.connect(p)
        deadline = Timer.scheduledTimer(withTimeInterval: 150, repeats: false) { [weak self] _ in self?.stop() }
    }
    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        guard active else { central.cancelPeripheralConnection(p); return }
        status = "Capturing — no medical alerts. Keep app open."
        p.discoverServices(nil)
        deadline?.invalidate()
        deadline = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in self?.stop() }
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        finish("Connection failed: \(error?.localizedDescription ?? "unknown error")")
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        finish("Disconnected. Values are historical. Check original monitor app resumes readings." + (error.map { " \($0.localizedDescription)" } ?? ""))
    }
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error { log(["error":error.localizedDescription]); return }
        let services = Set((p.services ?? []).map { $0.uuid.uuidString.uppercased() })
        if services.contains("FFE0") || services.contains("FFE5") || services.contains("FFA0") { profile = .nbo }
        else if services.contains("180D") { profile = .heartRate }
        else if services.contains("1822") { profile = .pulseOximeter }
        else if services.contains("1809") { profile = .thermometer }
        else { profile = .generic }
        for service in p.services ?? [] { p.discoverCharacteristics(nil, for: service) }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error { log(["error":error.localizedDescription]); return }
        for c in service.characteristics ?? [] {
            log(["event":"characteristic", "service":service.uuid.uuidString, "uuid":c.uuid.uuidString, "properties":String(c.properties.rawValue)])
            if c.properties.contains(.read) { p.readValue(for: c) }
            if c.properties.contains(.notify) || c.properties.contains(.indicate) { p.setNotifyValue(true, for: c) }
        }
    }
    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        log(["event":"subscription", "uuid":c.uuid.uuidString, "enabled":String(c.isNotifying), "error":error?.localizedDescription ?? ""])
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard active else { return }
        if let error = error { log(["error":error.localizedDescription, "uuid":c.uuid.uuidString]); return }
        guard let data = c.value else { return }
        let uuid = c.uuid.uuidString.uppercased()
        let key = (c.service?.uuid.uuidString ?? "?") + "/" + uuid
        if uuid == "2A37", c.service?.uuid.uuidString.uppercased() == "180D" {
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
        if uuid == "FFE7", c.service?.uuid.uuidString.uppercased() == "FFE0", data.count >= 6 {
            let candidateHeartRate = Int(data[3])
            let candidateOxygen = Int(data[5])
            ffe7HeartRateCandidate = (30...255).contains(candidateHeartRate) ? candidateHeartRate : nil
            ffe7OxygenCandidate = (70...100).contains(candidateOxygen) ? candidateOxygen : nil
            if ffe7HeartRateCandidate != nil || ffe7OxygenCandidate != nil {
                saveMeasurement(heartRate: ffe7HeartRateCandidate, oxygen: ffe7OxygenCandidate, source: "experimental-FFE7")
            }
        }
        // 2A5E/2A5F are standard pulse-ox measurements. Values stay hidden until
        // a complete standards-compliant parser is added; never infer from raw bytes.
        let hex = data.map { String(format:"%02x", $0) }.joined()
        log(["event":"sample", "uuid":uuid, "service":c.service?.uuid.uuidString ?? "?", "hex":hex])
        lastSample = Date()
        if let i = readings.firstIndex(where: { $0.id == key }) {
            readings[i].count += 1; readings[i].hex = hex
        } else { readings.append(Reading(id:key, count:1, hex:hex)) }
        if uuid == "2A19", data.count == 1, data[0] <= 100 { battery = "\(data[0])%" }
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

    func stop() {
        manager.stopScan()
        deadline?.invalidate()
        if let p = peripheral { manager.cancelPeripheralConnection(p) }
        finish("Capture stopped. Values are historical. Restore original monitor app readings.")
    }
    private func finish(_ message: String) {
        verifiedHeartRate = nil; verifiedOxygen = nil; ffe7HeartRateCandidate = nil; ffe7OxygenCandidate = nil
        measurementTime = nil; highRateSince = nil; previousHeartRateTime = nil; alarmActive = false
        active = false; deadline?.invalidate(); deadline = nil
        // Close first so a recording error cannot recurse into stop().
        let oldFile = file; file = nil
        try? oldFile?.synchronize(); try? oldFile?.close()
        peripheral = nil
        status = message
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
    @Binding var name: String
    @Binding var birthDate: Date
    @Binding var gender: String
    @Environment(\.dismiss) private var dismiss
    @State private var saved = false
    private let genders = ["Girl", "Boy", "Other", "Prefer not to say"]

    var body: some View {
        NavigationStack {
            Form {
                Section { Text("Nivvi is personalised to your child and stays on this iPhone by default.").font(.subheadline).foregroundStyle(.secondary) }
                Section("Child profile") {
                    TextField("Child’s name", text: $name)
                    DatePicker("Date of birth", selection: $birthDate, in: ...Date(), displayedComponents: .date)
                    Picker("Gender (optional)", selection: $gender) { ForEach(genders, id: \.self) { Text($0).tag($0) } }
                }
                Section { Button("Save profile") { saved = true; dismiss() }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
            .navigationTitle("Set up Nivvi")
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

struct ContentView: View {
    @StateObject private var monitor = Monitor()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("nivvi.profile.name") private var childName = ""
    @AppStorage("nivvi.profile.birthDate") private var childBirthDate = 0.0
    @AppStorage("nivvi.profile.gender") private var childGender = "Prefer not to say"
    @AppStorage("nivvi.family.code") private var familyCode = ""
    @AppStorage("nivvi.family.role") private var familyRole = "Primary monitor"
    @AppStorage("nivvi.demo.mode") private var demoMode = false
    @State private var showProfile = false
    @State private var selected: CBPeripheral?
    @State private var confirm = false
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
    private var connected: Bool { monitor.active }
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
        .alert("Start a short test?", isPresented: $confirm) {
            Button("Cancel", role: .cancel) {}
            Button("Start") { if let p = selected { monitor.connect(p) } }
        } message: {
            Text("This can interrupt the original monitor app. Use only when you are not relying on its alerts.")
        }
        .onAppear { if childName.isEmpty { showProfile = true } }
        .sheet(isPresented: $showProfile) { ProfileSetupView(name: $childName, birthDate: Binding(get: { birthDate }, set: { childBirthDate = $0.timeIntervalSince1970 }), gender: $childGender) }
        .onChange(of: scenePhase) { phase in if phase == .background { monitor.stop() } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(mode.greeting).font(.subheadline).foregroundStyle(.white.opacity(0.72))
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
                Text(connected ? "Capture active" : (demoMode ? "Demo history · not connected" : "Not connected")).font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(mode.rawValue) mode").font(.caption.weight(.bold)).padding(.horizontal, 11).padding(.vertical, 6)
                    .background(.white.opacity(0.12)).clipShape(Capsule())
            }
            if !ageText.isEmpty { Text("\(ageText) · \(childGender == "Prefer not to say" ? "" : childGender)").font(.caption).foregroundStyle(.white.opacity(0.6)) }
        }.padding(.top, 16).padding(.bottom, 18)
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
            if !monitor.status.isEmpty { Text(monitor.status).font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(2) }
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
            panel { HStack(spacing: 14) { Image(systemName: "wave.3.right.circle.fill").font(.largeTitle).foregroundStyle(teal); VStack(alignment: .leading) { Text("NBO wearable").font(.headline); Text(connected ? "Connected" : "Ready to connect").foregroundStyle(connected ? teal : .white.opacity(0.6)) }; Spacer() } }
            panel { VStack(alignment: .leading, spacing: 6) { Text("PROFILE").font(.caption.bold()).foregroundStyle(.white.opacity(0.55)); Text(monitor.profile.rawValue).font(.headline); Text("Nivvi only displays measurements when the Bluetooth format is recognised.").font(.caption).foregroundStyle(.white.opacity(0.6)) } }
            HStack(spacing: 14) { metric("Battery", monitor.battery == "—" ? "—" : monitor.battery); metric("Mode", mode.rawValue) }
            Button { monitor.active ? monitor.stop() : monitor.scan() } label: { Text(monitor.active ? "Stop capture" : "Scan for NBO").font(.headline).frame(maxWidth: .infinity).padding(17) }.buttonStyle(.borderedProminent).tint(coral)
            ForEach(monitor.devices, id: \.identifier) { p in Button("Capture \(p.name ?? "NBO") for 2 minutes") { selected = p; confirm = true }.buttonStyle(.bordered) }
            Text("The charger appears as NC0 and is not the wearable.").font(.caption).foregroundStyle(.white.opacity(0.55))
        }
    }

    private var settings: some View { VStack(alignment: .leading, spacing: 18) {
        Text("Settings").font(.largeTitle.bold())
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
                .onChange(of: monitor.highRateAlarmEnabled) { _ in monitor.silenceAlarm() }
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
