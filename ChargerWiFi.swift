import SwiftUI
import CoreBluetooth
import CoreLocation
import NetworkExtension

/// The Neebo charger advertises as NCO and keeps the home network on FFB0.
/// FFB1 is the network name, FFB2 is the write-only password, FFB3 is its reply.
final class ChargerSetup: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var status = "Looking for a charger named NCO."
    @Published var network = ""
    @Published var ready = false
    private var manager: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var nameChar: CBCharacteristic?
    private var passwordChar: CBCharacteristic?
    private var replyChar: CBCharacteristic?
    private var pendingPassword: Data?
    private var scan: Timer?

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
        self.peripheral = peripheral
        central.stopScan()
        scan?.invalidate()
        status = "Found \(name.isEmpty ? "NCO" : name). Connecting."
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        status = "Connected. Reading the saved network."
        peripheral.discoverServices([CBUUID(string: "FFB0")])
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
        guard let service = peripheral.services?.first(where: { BluetoothPolicy.normalized($0.uuid.uuidString) == "FFB0" }) else {
            status = "Connected, but this is not the charger service."
            return
        }
        peripheral.discoverCharacteristics(nil, for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] {
            switch BluetoothPolicy.normalized(characteristic.uuid.uuidString) {
            case "FFB1": nameChar = characteristic
            case "FFB2": passwordChar = characteristic
            case "FFB3": replyChar = characteristic
            default: break
            }
        }
        ready = nameChar != nil && passwordChar != nil
        if let nameChar { peripheral.readValue(for: nameChar) }
        if let replyChar {
            if replyChar.properties.contains(.notify) { peripheral.setNotifyValue(true, for: replyChar) }
            peripheral.readValue(for: replyChar)
        }
        if !ready { status = "Connected, but the Wi‑Fi settings were not found." }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value else { return }
        let id = BluetoothPolicy.normalized(characteristic.uuid.uuidString)
        if id == "FFB1" {
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters) ?? ""
            if !text.isEmpty { network = text }
            if ready && pendingPassword == nil { status = network.isEmpty ? "Charger ready." : "Charger is saved as \(network)." }
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
        }
    }

    private func write(_ data: Data, to characteristic: CBCharacteristic, on peripheral: CBPeripheral) {
        let type: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        peripheral.writeValue(data, for: characteristic, type: type)
        if type == .withoutResponse, characteristic === passwordChar {
            pendingPassword = nil
            status = "Sent. The charger is joining the network."
        }
    }

    private func isCharger(_ name: String, _ services: [CBUUID]) -> Bool {
        let upper = name.uppercased()
        if upper == "NCO" || upper == "NC0" || upper.contains("CHARGER") { return true }
        for service in services where BluetoothPolicy.normalized(service.uuidString) == "FFB0" {
            return true
        }
        return false
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
                Section("Charger") {
                    Text(charger.status)
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
            .navigationTitle("Charger Wi‑Fi")
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
