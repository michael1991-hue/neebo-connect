var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    precondition(condition(), "FAILED: \(name)")
    checks += 1
}
check(!ConnectionPhase.connecting.isConnected, "a connection request is not a confirmed connection")
check(ConnectionPhase.connecting.isBusy, "prevent simultaneous connection attempts")
check(ConnectionPhase.discovering.isConnected, "service discovery starts after connection")
check(!ConnectionPhase.stopping.isConnected && ConnectionPhase.stopping.isBusy, "disconnect callbacks settle before reuse")
check(!ConnectionPhase.idle.isBusy && !ConnectionPhase.scanning.isBusy, "selection permitted during and after scan")
check(BluetoothPolicy.isCandidate(names: [" nb0\n"], services: []), "normalise advertised names")
check(BluetoothPolicy.isCandidate(names: ["", "NBO"], services: []), "fallback peripheral name")
check(BluetoothPolicy.isCandidate(names: [], services: ["0000FFE0-0000-1000-8000-00805F9B34FB"]), "unnamed known service")
check(!BluetoothPolicy.isCandidate(names: ["NC0"], services: ["FFE0"]), "exclude known charger")
check(!BluetoothPolicy.isCandidate(names: ["Headphones"], services: ["180F"]), "battery alone is not wearable identity")
check(BluetoothPolicy.shouldObserve(service: "FFE0", characteristic: "FFE7"), "enable measurement stream")
check(BluetoothPolicy.shouldObserve(service: "180F", characteristic: "2A19"), "enable battery")
check(!BluetoothPolicy.shouldObserve(service: "FFA0", characteristic: "FFA1"), "do not subscribe to audio")
check(!BluetoothPolicy.shouldObserve(service: "FFE0", characteristic: "FF71"), "exclude unknown control path")
check(!BluetoothPolicy.shouldObserve(service: "FFA0", characteristic: "FFE7"), "validate service alongside characteristic")
let samples: [(Data, Int)] = [
    (Data([0,0,0,0x5F,0,0x63,0,0x3F,1]), 95),
    (Data([0,0,0,0x6C,0,0x63,0,0x3A,1]), 108),
    (Data([0,0,0,0x68,0,0x63,0,0x3B,1]), 104),
    (Data([0,0,0,0x66,0,0x63,0,0x3B,1]), 102)
]
for (bytes, expected) in samples {
    let value = BluetoothPolicy.ffe7(bytes)
    check(value.heartRate == expected && value.oxygen == 99, "captured FFE7 fixture \(expected)")
}
check(BluetoothPolicy.ffe7(Data()).heartRate == nil, "empty frame")
check(BluetoothPolicy.ffe7(Data([0,0,0,95,0,99])).heartRate == nil, "truncated frame must not appear live")
check(BluetoothPolicy.ffe7(Data([1,0,0,95,0,99,0,0,1])).heartRate == nil, "unknown leading fields")
check(BluetoothPolicy.ffe7(Data([0,0,0,95,1,99,0,0,1])).heartRate == nil, "do not truncate unknown high HR byte")
check(BluetoothPolicy.ffe7(Data([0,0,0,95,0,99,1,0,1])).oxygen == nil, "do not truncate unknown high oxygen byte")
let invalid = BluetoothPolicy.ffe7(Data(repeating: 0, count: 9))
check(invalid.heartRate == nil && invalid.oxygen == nil, "clear candidates when no usable measurement")
let partial = BluetoothPolicy.ffe7(Data([0,0,0,0,0,99,0,0,1]))
check(partial.heartRate == nil && partial.oxygen == 99, "validate each field independently")
let record = SavedMeasurement(time: Date(timeIntervalSince1970: 12345), heartRate: 104, oxygen: 99, source: "experimental-FFE7")
let reloaded = try JSONDecoder().decode([SavedMeasurement].self, from: JSONEncoder().encode([record]))
check(reloaded[0].id == record.id && reloaded[0].time == record.time && reloaded[0].source == "experimental-FFE7", "persist experimental label, time and identity")
print("Passed \(checks) regression checks")
