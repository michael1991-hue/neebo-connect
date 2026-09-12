import SwiftUI
import CoreBluetooth

struct Reading: Identifiable {
    let id: String
    var count: Int
    var hex: String
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
    private var manager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var file: FileHandle?
    private var deadline: Timer?
    private let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    override init() {
        super.init()
        manager = CBCentralManager(delegate: self, queue: .main)
        refreshFiles()
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
        battery = "—"; counter = "—"; readings = []; lastSample = nil; recording = nil
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
        finish("Disconnected. Values are historical. Check original Neebo app resumes readings." + (error.map { " \($0.localizedDescription)" } ?? ""))
    }
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error { log(["error":error.localizedDescription]); return }
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
        let uuid = c.uuid.uuidString
        let key = (c.service?.uuid.uuidString ?? "?") + "/" + uuid
        let hex = data.map { String(format:"%02x", $0) }.joined()
        log(["event":"sample", "uuid":uuid, "service":c.service?.uuid.uuidString ?? "?", "hex":hex])
        lastSample = Date()
        if let i = readings.firstIndex(where: { $0.id == key }) {
            readings[i].count += 1; readings[i].hex = hex
        } else { readings.append(Reading(id:key, count:1, hex:hex)) }
        if uuid == "2A19", data.count == 1, data[0] <= 100 { battery = "\(data[0])%" }
        if uuid == "FFEA", data.count == 2 { counter = "\(Int(data[0]) | (Int(data[1]) << 8)) — possible minutes" }
    }
    func stop() {
        manager.stopScan()
        deadline?.invalidate()
        if let p = peripheral { manager.cancelPeripheralConnection(p) }
        finish("Capture stopped. Values are historical. Restore original Neebo app readings.")
    }
    private func finish(_ message: String) {
        active = false; deadline?.invalidate(); deadline = nil
        // Close first so a recording error cannot recurse into stop().
        let oldFile = file; file = nil
        try? oldFile?.synchronize(); try? oldFile?.close()
        peripheral = nil
        status = message
        refreshFiles()
    }
}

struct ContentView: View {
    @StateObject private var monitor = Monitor()
    @Environment(\.scenePhase) private var scenePhase
    @State private var selected: CBPeripheral?
    @State private var confirm = false
    private let navy = Color(red:0.02, green:0.13, blue:0.23)
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading, spacing:20) {
                    Text("Neebo Connect").font(.largeTitle.bold())
                    Text("RESEARCH PROTOTYPE • No medical alerts").font(.caption).foregroundStyle(.yellow)
                    Text(monitor.status).foregroundStyle(.cyan)
                    card("Battery", monitor.battery, "Standard Bluetooth battery value")
                    card("Heart rate", "Not decoded", "No guessed measurements")
                    card("Blood oxygen", "Not decoded", "No guessed measurements")
                    card("FFEA counter", monitor.counter, "Sleep duration is unverified")
                    if let date = monitor.lastSample {
                        Text("Last sample: \(date.formatted(date:.omitted, time:.standard))").font(.caption)
                    }
                    HStack {
                        Button("Scan", action:monitor.scan).disabled(monitor.active)
                        Button("Stop", action:monitor.stop)
                    }.buttonStyle(.borderedProminent)
                    ForEach(monitor.devices, id:\.identifier) { p in
                        Button("Capture \(p.name ?? "NB0") for 2 minutes") { selected = p; confirm = true }
                            .disabled(monitor.active)
                    }
                    Text("Raw data • \(monitor.readings.reduce(0) { $0 + $1.count }) samples").font(.headline)
                    ForEach(monitor.readings) { r in
                        VStack(alignment:.leading) {
                            Text("\(r.id) • \(r.count) samples").font(.caption.bold())
                            Text(r.hex).font(.system(.caption, design:.monospaced)).textSelection(.enabled)
                        }
                    }
                    Text("Saved recordings").font(.headline)
                    Text("Stop capture before sharing. Files also appear in Files → On My iPhone → Neebo Connect.").font(.caption)
                    ForEach(monitor.files, id:\.self) { url in
                        ShareLink(item:url) { Label(url.lastPathComponent, systemImage:"square.and.arrow.up").font(.caption) }
                            .disabled(monitor.active)
                    }
                }.padding(24)
            }.background(navy).foregroundStyle(.white)
            .alert("Start a short test?", isPresented:$confirm) {
                Button("Cancel", role:.cancel) {}
                Button("Start") { if let p = selected { monitor.connect(p) } }
            } message: {
                Text("This can interrupt the original Neebo app. Test only when you are not relying on its alerts. Keep this app open, then reconnect the original app after testing.")
            }
            .onChange(of:scenePhase) { phase in
                if phase == .background { monitor.stop() }
            }
        }.preferredColorScheme(.dark)
    }
    private func card(_ title:String, _ value:String, _ note:String) -> some View {
        VStack(alignment:.leading, spacing:7) {
            Text(title).font(.headline).foregroundStyle(.cyan)
            Text(value).font(.title2.bold())
            Text(note).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth:.infinity, alignment:.leading).padding(18).background(.white.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius:18))
    }
}

@main
struct NeeboConnectApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}
