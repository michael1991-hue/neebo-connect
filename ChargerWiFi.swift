import SwiftUI
import CoreBluetooth
import CoreLocation
import NetworkExtension

/// The Neebo charger advertises as NCO and keeps the home network on FFB0.
/// FFB1 is the network name, FFB2 is the write-only password, FFB3 is its reply.
final class ChargerSetup: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var status = "Looking for a charger named NCO."
    @Published var network = ""
    @Published var server = ""
    @Published var ready = false
    @Published var serverReady = false
    private var manager: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var nameChar: CBCharacteristic?
    private var passwordChar: CBCharacteristic?
    private var replyChar: CBCharacteristic?
    private var serverChar: CBCharacteristic?
    private var pendingPassword: Data?
    private var pendingServices = 0
    private var claimWhenConfirmed = false
    private var serial = ""
    private var scan: Timer?
    private let nivviServer = "mqtt.nivvi.app"

    func start() {
        ready = false
        if manager == nil {
            manager = CBCentralManager(delegate: self, queue: .main)
        } else if manager?.state == .poweredOn {
            look()
        }
    }

    func stop() {
        scan?.invalidate()
        manager?.stopScan()
        if let peripheral { manager?.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        ready = false
        pendingPassword = nil
        serverReady = false
    }

    func useNivviServer() {
        guard serverReady, let peripheral, let serverChar else {
            status = "The charger is not ready."
            return
        }
        status = "Sending the Nivvi server."
        claimWhenConfirmed = true
        write(Data(nivviServer.utf8), to: serverChar, on: peripheral)
    }

    func send(network: String, password: String) {
        let trimmed = network.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ready, let peripheral, let nameChar, let passwordChar, !trimmed.isEmpty, !password.isEmpty else {
            status = "The charger is not ready."
            return
        }
        pendingPassword = Data(password.utf8)
        status = "Sending the network name."
        write(Data(trimmed.utf8), to: nameChar, on: peripheral)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn { look() }
        else { status = "Bluetooth is off." }
    }

    private func look() {
        guard let manager, manager.state == .poweredOn else { return }
        status = "Looking for a charger named NCO."
        manager.scanForPeripherals(withServices: nil, options: nil)
        scan?.invalidate()
        scan = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
            guard let self, self.peripheral == nil else { return }
            self.manager?.stopScan()
            self.status = "No charger found. Keep it plugged in and close to this iPhone."
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advertised = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? advertised ?? ""
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        guard self.peripheral == nil, isCharger(name, services) else { return }
        rememberSerial(name)
        if let local = advertised { rememberSerial(local) }
        if let maker = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data {
            rememberSerial(String(data: maker, encoding: .utf8) ?? "")
        }
        self.peripheral = peripheral
        central.stopScan()
        scan?.invalidate()
        status = "Found \(name.isEmpty ? "NCO" : name). Connecting."
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        status = "Connected. Reading the charger."
        peripheral.discoverServices([CBUUID(string: "FFB0"), CBUUID(string: "FFC0"), CBUUID(string: "FFD0")])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        self.peripheral = nil
        status = "Could not connect. Move the iPhone closer and try again."
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        ready = false
        if status.hasPrefix("Sent") { return }
        status = "The charger disconnected."
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = (peripheral.services ?? []).filter {
            let id = BluetoothPolicy.normalized($0.uuid.uuidString)
            return id == "FFB0" || id == "FFC0" || id == "FFD0"
        }
        guard !services.isEmpty else {
            status = "Connected, but this is not the charger."
            return
        }
        pendingServices = services.count
        for service in services { peripheral.discoverCharacteristics(nil, for: service) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] {
            switch BluetoothPolicy.normalized(characteristic.uuid.uuidString) {
            case "FFB1": nameChar = characteristic
            case "FFB2": passwordChar = characteristic
            case "FFB3": replyChar = characteristic
            case "FFC1": serverChar = characteristic
            default: break
            }
            if characteristic.properties.contains(.read), BluetoothPolicy.normalized(characteristic.uuid.uuidString) != "FFB2" {
                peripheral.readValue(for: characteristic)
            }
        }
        pendingServices = max(0, pendingServices - 1)
        guard pendingServices == 0 else { return }
        ready = nameChar != nil && passwordChar != nil
        serverReady = serverChar != nil
        if let nameChar { peripheral.readValue(for: nameChar) }
        if let serverChar { peripheral.readValue(for: serverChar) }
        if let replyChar {
            if replyChar.properties.contains(.notify) { peripheral.setNotifyValue(true, for: replyChar) }
            peripheral.readValue(for: replyChar)
        }
        if serverReady { status = serial.isEmpty ? "Connected to NCO. Reading its serial." : "This charger is NC\(serial)." }
        else if !ready { status = "Connected, but the charger settings were not found." }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value else { return }
        let id = BluetoothPolicy.normalized(characteristic.uuid.uuidString)
        if id == "FFD3" { rememberSerial(Self.serialNumber(in: data) ?? "") }
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters) ?? ""
        rememberSerial(text)
        if id == "FFB1" {
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters) ?? ""
            if !text.isEmpty { network = text }
            if ready && pendingPassword == nil && !status.hasPrefix("Sending") {
                status = network.isEmpty ? "Charger ready." : "Charger is saved as \(network)."
                if !serial.isEmpty { status = "NC\(serial). " + status }
            }
        } else if id == "FFC1" {
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters) ?? ""
            server = text
            status = text == nivviServer ? "This charger uses the Nivvi server." : "Server is \(text.isEmpty ? "not set" : text)."
            if !serial.isEmpty { status = "NC\(serial). " + status }
            if claimWhenConfirmed && text == nivviServer {
                claimWhenConfirmed = false
                Task { await self.linkToFamily() }
            }
        } else if id == "FFB3" {
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters) ?? ""
            if !text.isEmpty { status = "Charger says \(text)." }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            pendingPassword = nil
            status = "The charger refused the write. \(error.localizedDescription)"
            return
        }
        if BluetoothPolicy.normalized(characteristic.uuid.uuidString) == "FFB1", let password = pendingPassword, let passwordChar {
            status = "Sending the password."
            pendingPassword = nil
            write(password, to: passwordChar, on: peripheral)
        } else if BluetoothPolicy.normalized(characteristic.uuid.uuidString) == "FFB2" {
            status = "Sent. The charger is joining the network."
            if let replyChar { peripheral.readValue(for: replyChar) }
        } else if characteristic === serverChar {
            peripheral.readValue(for: characteristic)
        }
    }

    private func write(_ data: Data, to characteristic: CBCharacteristic, on peripheral: CBPeripheral) {
        let type: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        peripheral.writeValue(data, for: characteristic, type: type)
        if type == .withoutResponse, characteristic === passwordChar {
            pendingPassword = nil
            status = "Sent. The charger is joining the network."
        } else if type == .withoutResponse, characteristic === serverChar {
            status = "Sent. Reading it back."
            peripheral.readValue(for: characteristic)
        }
    }

    private func isCharger(_ name: String, _ services: [CBUUID]) -> Bool {
        let upper = name.uppercased()
        if upper == "NCO" || upper == "NC0" || upper.contains("CHARGER") || upper.range(of: #"^NC\d{3,8}$"#, options: .regularExpression) != nil { return true }
        for service in services where BluetoothPolicy.normalized(service.uuidString) == "FFB0" {
            return true
        }
        return false
    }

    private func linkToFamily() async {
        guard !serial.isEmpty else {
            status = "Connected, but this charger did not give its serial. Move closer and try again."
            return
        }
        do {
            try await FamilyRelay.shared.claimCharger(serial: serial)
            status = "NC\(serial) is linked to your family."
        } catch {
            status = error.localizedDescription
        }
    }

    private func rememberSerial(_ text: String) {
        guard serial.isEmpty, let found = Self.serialNumber(in: text) else { return }
        serial = found
        if !status.hasPrefix("Sending") && !status.hasPrefix("Sent") {
            status = "This charger is NC\(found)."
        }
    }

    static func serialNumber(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = trimmed.uppercased()
        if upper == "NCO" || upper == "NC0" { return nil }
        if let match = upper.range(of: #"NC(\d{3,8})"#, options: .regularExpression) {
            return String(upper[match].dropFirst(2))
        }
        if trimmed.range(of: #"^\d{4,6}$"#, options: .regularExpression) != nil { return trimmed }
        return nil
    }

    /// FFD3 is the serial, little-endian. 22 2C 00 00 is 11298.
    static func serialNumber(in data: Data) -> String? {
        guard data.count >= 2, data[0] != 0 || data[1] != 0 else { return nil }
        let serial = UInt32(data[0]) | (UInt32(data[1]) << 8)
        guard (1000...999999).contains(serial) else { return nil }
        if data.count >= 4, data[2] != 0 || data[3] != 0 { return nil }
        return String(serial)
    }
}

struct ChargerWiFiView: View {
    @StateObject private var charger = ChargerSetup()
    @StateObject private var phone = PhoneNetwork()
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""
    @State private var chosen = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Nivvi server") {
                    Text(charger.status)
                    Text(charger.server.isEmpty ? "Not read yet." : charger.server)
                    Button("Use Nivvi server") { charger.useNivviServer() }
                        .disabled(!charger.serverReady)
                }
                Section {
                    if !phone.name.isEmpty {
                        Button { choose(phone.name) } label: {
                            Label("This iPhone is on \(phone.name)", systemImage: "iphone")
                        }
                    } else if !phone.note.isEmpty {
                        Text(phone.note).font(.footnote).foregroundStyle(.secondary)
                    }
                    if !charger.network.isEmpty {
                        Button { choose(charger.network) } label: {
                            Label("Saved on the charger: \(charger.network)", systemImage: "wifi")
                        }
                    }
                    TextField("Other network name", text: $typed)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Use this name") { choose(typed) }
                        .disabled(typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: {
                    Text("Choose a network")
                } footer: {
                    Text("The password is asked after you choose. It is sent to the charger and is not kept in Nivvi.")
                }
                if !chosen.isEmpty {
                    Section("Password for \(chosen)") {
                        SecureField("Password", text: $password)
                        Button("Send to charger") { charger.send(network: chosen, password: password) }
                            .disabled(!charger.ready || password.isEmpty)
                    }
                }
            }
            .navigationTitle("Charger")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { charger.stop(); dismiss() }
                }
            }
            .onAppear {
                charger.start()
                phone.look()
            }
            .onDisappear { charger.stop() }
        }
    }

    private func choose(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        chosen = trimmed
        password = ""
    }
}

private final class PhoneNetwork: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var name = ""
    @Published var note = ""
    private let location = CLLocationManager()

    func look() {
        location.delegate = self
        switch location.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            read()
        case .notDetermined:
            location.requestWhenInUseAuthorization()
        default:
            note = "Allow Location for Nivvi so it can see the Wi‑Fi this iPhone is on."
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            read()
        case .denied, .restricted:
            note = "Allow Location for Nivvi so it can see the Wi‑Fi this iPhone is on."
        default:
            break
        }
    }

    private func read() {
        NEHotspotNetwork.fetchCurrent { [weak self] network in
            DispatchQueue.main.async {
                let ssid = network?.ssid ?? ""
                self?.name = ssid
                self?.note = ssid.isEmpty ? "This iPhone did not share the Wi‑Fi name. You can still type it." : ""
            }
        }
    }
}
