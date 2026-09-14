import Foundation

// Standard Bluetooth Pulse Oximeter Service (1822), PLXS 1.0.1.
// Protocol decoding is not a device-accuracy or clinical-validation claim.
struct PulseOximetrySample {
    let pulse: Double?
    let oxygen: Double?
    let continuous: Bool
    let measurementStatus: UInt16?
    let sensorStatus: UInt32?
    let deviceTime: String?
    let clockUnset: Bool
    var fromStorage: Bool { (measurementStatus ?? 0) & 0x0200 != 0 }
    var usable: Bool {
        // Accept neutral/validated/qualified status. Withhold early, ongoing,
        // stored, demo, test, calibration and suspect data from live values.
        (measurementStatus ?? 0) & ~UInt16(0x0180) == 0 && (sensorStatus ?? 0) == 0
    }
    var liveEligible: Bool { continuous && usable }
    var description: String {
        "Pulse \(pulse.map(MetricText.number) ?? "unavailable") bpm · Oxygen \(oxygen.map(MetricText.number) ?? "unavailable")%"
    }
}

enum MetricText {
    static func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...4))) }
}

enum PulseOximetry {
    static func sfloat(_ word: UInt16) -> Double? {
        // IEEE 11073 signed 12-bit mantissa and signed 4-bit decimal exponent.
        // IEEE 11073 reserves these complete 16-bit encodings for NaN, +/-Inf,
        // and reserved/unavailable values. Compare the complete word.
        guard ![UInt16(0x07FE), 0x07FF, 0x0800, 0x0801, 0x0802].contains(word) else { return nil }
        let raw = word & 0x0FFF
        let mantissa = raw & 0x0800 == 0 ? Int(raw) : Int(raw) - 4096
        let high = Int(word >> 12)
        let exponent = high >= 8 ? high - 16 : high
        let value = Double(mantissa) * pow(10, Double(exponent))
        return value.isFinite ? value : nil
    }
    static func decode(_ data: Data, characteristic: String) -> PulseOximetrySample? {
        let uuid = BluetoothPolicy.normalized(characteristic)
        guard uuid == "2A5E" || uuid == "2A5F" else { return nil }
        let bytes = Array(data)
        guard bytes.count >= 5, bytes[0] & 0xE0 == 0 else { return nil }
        let flags = bytes[0], continuous = uuid == "2A5F"
        func word(_ i: Int) -> UInt16 { UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8 }
        let oxygen = sfloat(word(1)).flatMap { (0...100).contains($0) ? $0 : nil }
        let pulse = sfloat(word(3)).flatMap { $0 > 0 && $0 <= 65535 ? $0 : nil }
        var cursor = 5
        var timestamp: String?
        if continuous {
            if flags & 1 != 0 { cursor += 4 }
            if flags & 2 != 0 { cursor += 4 }
        } else if flags & 1 != 0 {
            guard bytes.count >= cursor + 7 else { return nil }
            let year = Int(word(cursor)), month = Int(bytes[cursor + 2]), day = Int(bytes[cursor + 3])
            let hour = Int(bytes[cursor + 4]), minute = Int(bytes[cursor + 5]), second = Int(bytes[cursor + 6])
            guard (year == 0 || (1582...9999).contains(year)), month <= 12, day <= 31, hour <= 23, minute <= 59, second <= 59 else { return nil }
            // Keep device-local components, without inventing a time zone or using
            // an unverified device clock as the iPhone's live receipt timestamp.
            timestamp = String(format: "%04d-%02d-%02d %02d:%02d:%02d (device clock)", year, month, day, hour, minute, second)
            cursor += 7
        }
        guard bytes.count >= cursor else { return nil }
        var status: UInt16?, sensor: UInt32?
        if flags & (continuous ? 4 : 2) != 0 {
            guard bytes.count >= cursor + 2 else { return nil }
            status = word(cursor); cursor += 2
        }
        if flags & (continuous ? 8 : 4) != 0 {
            guard bytes.count >= cursor + 3 else { return nil }
            sensor = UInt32(bytes[cursor]) | UInt32(bytes[cursor + 1]) << 8 | UInt32(bytes[cursor + 2]) << 16
            cursor += 3
        }
        if flags & (continuous ? 16 : 8) != 0 { cursor += 2 }
        guard bytes.count == cursor else { return nil }
        return PulseOximetrySample(pulse: pulse, oxygen: oxygen, continuous: continuous, measurementStatus: status, sensorStatus: sensor, deviceTime: timestamp, clockUnset: !continuous && flags & 16 != 0)
    }
}
